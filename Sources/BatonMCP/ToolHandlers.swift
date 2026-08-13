import BatonCore
import Foundation

/// Turns tool arguments into store operations.
struct ToolHandlers {
    let store: TaskStore

    enum Failure: Swift.Error, CustomStringConvertible {
        case unknownTool(String)
        case missingArgument(String)
        case notFound(String)
        case rejected(String)

        var description: String {
            switch self {
            case .unknownTool(let name): return "Baton has no tool named '\(name)'."
            case .missingArgument(let name): return "The argument '\(name)' is required."
            case .notFound(let id): return "No task with id '\(id)'. It may have been pruned."
            case .rejected(let reason): return reason
            }
        }
    }

    func call(name: String, arguments: JSONValue) throws -> JSONValue {
        switch name {
        case "ask_human": return try askHuman(arguments)
        case "submit_task": return try submitTask(arguments)
        case "await_task": return try awaitTask(arguments)
        case "get_task": return try getTask(arguments)
        case "list_tasks": return try listTasks(arguments)
        case "cancel_task": return try cancelTask(arguments)
        default: throw Failure.unknownTool(name)
        }
    }

    // MARK: - ask_human

    private func askHuman(_ arguments: JSONValue) throws -> JSONValue {
        guard let question = arguments["question"]?.stringValue, !question.isEmpty else {
            throw Failure.missingArgument("question")
        }
        var normalized = arguments.objectValue ?? [:]
        normalized["title"] = .string(question)
        if let details = arguments["details"] { normalized["body"] = details }

        let result = try create(.object(normalized))
        let wait = clampWait(arguments["waitSeconds"]?.doubleValue)
        let settled = waitForResolution(id: result.task.id, timeout: wait)
        return report(settled ?? result.task, deduplicated: result.wasDeduplicated, waited: wait)
    }

    // MARK: - submit_task

    private func submitTask(_ arguments: JSONValue) throws -> JSONValue {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw Failure.missingArgument("title")
        }
        let result = try create(arguments)
        return report(result.task, deduplicated: result.wasDeduplicated, waited: nil)
    }

    // MARK: - await_task

    private func awaitTask(_ arguments: JSONValue) throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw Failure.missingArgument("id")
        }
        guard let existing = try store.task(id: id) else { throw Failure.notFound(id) }
        if existing.status.isResolved { return report(existing, deduplicated: false, waited: nil) }

        let wait = clampWait(arguments["waitSeconds"]?.doubleValue)
        let settled = waitForResolution(id: id, timeout: wait)
        return report(settled ?? existing, deduplicated: false, waited: wait)
    }

    // MARK: - get_task

    private func getTask(_ arguments: JSONValue) throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw Failure.missingArgument("id")
        }
        guard let task = try store.task(id: id) else { throw Failure.notFound(id) }
        return report(task, deduplicated: false, waited: nil)
    }

    // MARK: - list_tasks

    private func listTasks(_ arguments: JSONValue) throws -> JSONValue {
        let filter = arguments["status"]?.stringValue ?? "open"
        let statuses: [BatonTask.Status]?
        switch filter {
        case "any": statuses = nil
        case "open": statuses = BatonTask.Status.allCases.filter(\.isOpen)
        default: statuses = BatonTask.Status(rawValue: filter).map { [$0] } ?? BatonTask.Status.allCases.filter(\.isOpen)
        }
        let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 200)
        let tasks = try store.tasks(statuses: statuses, sessionId: arguments["sessionId"]?.stringValue, limit: limit)
        return .object([
            "count": .number(Double(tasks.count)),
            "tasks": .array(tasks.map { summary($0) }),
        ])
    }

    // MARK: - cancel_task

    private func cancelTask(_ arguments: JSONValue) throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw Failure.missingArgument("id")
        }
        guard let task = try store.task(id: id) else { throw Failure.notFound(id) }
        if task.status.isResolved {
            return .object([
                "id": .string(id),
                "status": .string(task.status.rawValue),
                "note": "The task was already resolved. Nothing changed.",
            ])
        }
        let reason = arguments["reason"]?.stringValue ?? "The agent no longer needs an answer."
        let updated = try store.respond(id: id, response: .init(decision: .cancelled, text: reason))
        WakeSignal.post()
        return report(updated ?? task, deduplicated: false, waited: nil)
    }

    // MARK: - Creation

    private func create(_ arguments: JSONValue) throws -> TaskStore.SubmitResult {
        let sessionId = arguments["sessionId"]?.stringValue
        try Guardrails.checkRate(store: store, sessionId: sessionId)

        let worktree = arguments["worktree"]?.stringValue
        let repo = worktree.flatMap { GitProbe.describe(path: $0) }
            ?? worktree.map { BatonTask.RepoRef(worktreePath: ($0 as NSString).expandingTildeInPath) }

        let baseRef = arguments["baseRef"]?.stringValue
        let summary = (repo?.worktreePath).flatMap { path in
            baseRef.flatMap { _ in
                GitProbe.changeSummary(path: path, baseRef: baseRef, headRef: arguments["headRef"]?.stringValue)
            }
        }

        let choices = ArgumentParsing.choices(arguments["choices"])
        let inferredKind = BatonTask.Kind(rawValue: arguments["kind"]?.stringValue ?? "")
            ?? ArgumentParsing.inferKind(hasChoices: !choices.isEmpty, hasSummary: summary != nil, hasLinks: arguments["links"] != nil)

        let timeoutSeconds = arguments["timeoutSeconds"]?.doubleValue
        let task = BatonTask(
            status: .pending,
            kind: inferredKind,
            priority: BatonTask.Priority(rawValue: arguments["priority"]?.stringValue ?? "") ?? .normal,
            title: arguments["title"]?.stringValue ?? "Untitled task",
            body: arguments["body"]?.stringValue,
            agent: BatonTask.AgentRef(
                name: arguments["agentName"]?.stringValue ?? ProcessInfo.processInfo.environment["BATON_AGENT_NAME"] ?? "agent",
                harness: ProcessInfo.processInfo.environment["BATON_HARNESS"],
                model: ProcessInfo.processInfo.environment["BATON_MODEL"],
                sessionId: sessionId ?? ProcessInfo.processInfo.environment["BATON_SESSION_ID"],
                pid: getppid()
            ),
            repo: repo,
            links: ArgumentParsing.links(arguments["links"]),
            choices: choices,
            checklist: ArgumentParsing.checklist(arguments["checklist"]),
            changeSummary: summary,
            timeoutAt: timeoutSeconds.map { Date().addingTimeInterval($0) },
            onTimeout: BatonTask.TimeoutPolicy(rawValue: arguments["onTimeout"]?.stringValue ?? "") ?? .wait,
            dedupeKey: arguments["dedupeKey"]?.stringValue
        )

        let result = try store.submit(Guardrails.sanitize(task))
        if !result.wasDeduplicated {
            WakeSignal.post()
            AppLauncher.nudge()
        }
        return result
    }

    // MARK: - Waiting

    private func clampWait(_ requested: Double?) -> TimeInterval {
        let value = requested ?? Guardrails.defaultBlockingWait
        return min(max(value, 0), Guardrails.maxBlockingWait)
    }

    /// Polls one row until it resolves. The store is the source of truth, so a
    /// poll cannot miss an answer the way a dropped signal could.
    private func waitForResolution(id: String, timeout: TimeInterval) -> BatonTask? {
        let deadline = Date().addingTimeInterval(timeout)
        var interval: useconds_t = 200_000
        while Date() < deadline {
            // Let a deadline pass into `expired` even when no app is running.
            _ = try? store.expireOverdue()
            if let task = try? store.task(id: id), task.status.isResolved {
                return task
            }
            usleep(interval)
            // Back off, but keep the cap low. This is the latency between the
            // human pressing Approve and the agent continuing, so a few hundred
            // milliseconds is worth four small SQLite reads a second.
            interval = min(interval * 2, 300_000)
        }
        return try? store.task(id: id)
    }

    // MARK: - Output shaping

    /// The agent-facing view of a task. Keep it small and add a `nextStep` line,
    /// because that line decides what the agent does next.
    private func report(_ task: BatonTask, deduplicated: Bool, waited: TimeInterval?) -> JSONValue {
        var payload: [String: JSONValue?] = [
            "id": .string(task.id),
            "status": .string(task.status.rawValue),
            "title": .string(task.title),
            "createdAt": .string(ISO8601DateFormatter().string(from: task.createdAt)),
        ]
        if deduplicated {
            payload["deduplicated"] = .bool(true)
            payload["note"] = .string("An open task with this dedupeKey already exists. Baton did not create a second one.")
        }
        if let repo = task.repo {
            payload["worktree"] = .string(repo.worktreePath)
            payload["branch"] = .string(repo.branch)
        }
        if let response = task.response {
            payload["response"] = responseValue(response, task: task)
        }
        payload["nextStep"] = .string(nextStep(for: task, waited: waited))
        return .object(compacting: payload)
    }

    private func responseValue(_ response: BatonTask.Response, task: BatonTask) -> JSONValue {
        var payload: [String: JSONValue?] = [
            "decision": .string(response.decision.rawValue),
            "text": .string(response.text),
            "respondedAt": .string(ISO8601DateFormatter().string(from: response.respondedAt)),
        ]
        if let choiceId = response.choiceId {
            payload["choiceId"] = .string(choiceId)
            payload["choiceLabel"] = .string(task.choices.first { $0.id == choiceId }?.label)
        }
        if !response.checklist.isEmpty {
            payload["checklist"] = .array(response.checklist.map { item in
                .object([
                    "text": .string(item.text),
                    "checked": .bool(item.checked),
                    "required": .bool(item.required),
                ])
            })
            let unmet = response.unmetItems
            if !unmet.isEmpty {
                payload["failedChecks"] = .array(unmet.map { .string($0.text) })
            }
        }
        return .object(compacting: payload)
    }

    private func nextStep(for task: BatonTask, waited: TimeInterval?) -> String {
        switch task.status {
        case .pending, .active, .snoozed:
            if let waited, waited > 0 {
                return "No answer in \(Int(waited))s. The task is still open. Call await_task with this id to keep waiting, "
                    + "or end your turn and call get_task later. Do not submit the task again."
            }
            return "The task is queued. Call await_task with this id to wait, or get_task later to check."
        case .done:
            guard let response = task.response else { return "Resolved." }
            switch response.decision {
            case .chose: return "The human chose an option. Follow it."
            case .answered: return "The human answered. Use the text in the response."
            default: return "Approved. Continue with the work."
            }
        case .sentBack:
            let unmet = task.response?.unmetItems ?? []
            if !unmet.isEmpty {
                return "The human returned the task. These checks failed: "
                    + unmet.map(\.text).joined(separator: "; ")
                    + ". Fix those, then submit a new task."
            }
            return "The human returned the task with feedback. Read response.text, fix it, then submit a new task."
        case .expired:
            switch task.onTimeout {
            case .proceed: return "Nobody answered before the deadline. Use your own judgement and note the assumption."
            case .abort: return "Nobody answered before the deadline. Stop this line of work and report that you are blocked."
            case .wait: return "The task expired. Ask again only if it still matters."
            }
        case .cancelled:
            return "The task was cancelled. No answer is coming."
        }
    }

    private func summary(_ task: BatonTask) -> JSONValue {
        .object(compacting: [
            "id": .string(task.id),
            "status": .string(task.status.rawValue),
            "kind": .string(task.kind.rawValue),
            "priority": .string(task.priority.rawValue),
            "title": .string(task.title),
            "branch": .string(task.repo?.branch),
            "worktree": .string(task.repo?.worktreePath),
            "decision": .string(task.response?.decision.rawValue),
        ])
    }
}
