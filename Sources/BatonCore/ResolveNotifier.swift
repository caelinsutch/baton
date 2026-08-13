import Foundation

/// Runs the human's resolve hook, so an agent that ended its turn learns the
/// answer instead of waiting for its next run.
///
/// The blocked case does not need this. An agent inside `ask_human` or
/// `await_task` polls the store and sees the answer within about a second. This
/// exists for the other case: the agent submitted a task, finished its turn, and
/// is no longer running.
public enum ResolveNotifier {
    /// Fires the hook for a resolved task. Never throws, and never blocks the
    /// caller for long: answering the next task must not wait on a wake command.
    public static func fire(task: BatonTask, config: BatonConfig = .load()) {
        guard let hook = config.onResolve else { return }
        guard let response = task.response else { return }

        let decision = response.decision.rawValue
        if !hook.decisions.isEmpty, !hook.decisions.contains(decision) { return }

        let sessionId = task.agent.sessionId ?? ""
        if hook.requireSessionId, sessionId.isEmpty { return }

        // An absolute path only. No shell, so nothing in a task payload can be
        // interpreted as a command, a pipe, or a redirection.
        guard hook.command.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: hook.command) else {
            return
        }

        let values = substitutions(task: task, response: response)
        let arguments = hook.args.map { expand($0, with: values) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hook.command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if let worktree = task.repo?.worktreePath,
           FileManager.default.fileExists(atPath: worktree) {
            process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        }

        do {
            try process.run()
        } catch {
            return
        }

        // Do not wait. A wake command may start a whole agent run, and the human
        // must be free to answer the next task at once.
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
        }
    }

    private static func substitutions(
        task: BatonTask,
        response: BatonTask.Response
    ) -> [String: String] {
        let failed = response.unmetItems.map(\.text).joined(separator: "; ")
        return [
            "id": task.id,
            "sessionId": task.agent.sessionId ?? "",
            "agent": task.agent.name,
            "decision": response.decision.rawValue,
            "status": task.status.rawValue,
            "title": task.title,
            "text": response.text ?? "",
            "worktree": task.repo?.worktreePath ?? "",
            "branch": task.repo?.branch ?? "",
            "failedChecks": failed,
        ]
    }

    /// Replaces `{name}` placeholders. An unknown placeholder becomes empty
    /// rather than staying literal, so a stray brace cannot confuse an agent.
    private static func expand(_ template: String, with values: [String: String]) -> String {
        var result = ""
        var remainder = Substring(template)

        while let open = remainder.firstIndex(of: "{") {
            result += remainder[remainder.startIndex..<open]
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "}") else {
                result += remainder[open...]
                return result
            }
            let name = String(remainder[afterOpen..<close])
            result += values[name] ?? ""
            remainder = remainder[remainder.index(after: close)...]
        }
        result += remainder
        return result
    }
}
