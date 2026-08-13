import BatonCore
import Foundation

/// Shell subcommands. These exist so you can test the loop without an agent:
/// submit in one terminal, watch the notch, then respond and see the result.
enum CLI {
    static let usage = """
    baton-mcp — agent-to-human task handoff

    USAGE
      baton-mcp [serve]                 Run the MCP server on stdio (default).
      baton-mcp submit <title> [flags]  Queue a task.
      baton-mcp list [--all]            Show tasks.
      baton-mcp respond <id> <decision> [text]
                                        decision: approve | back | answer | cancel
      baton-mcp watch <id> [--timeout N]
                                        Block until the task resolves, then print
                                        the decision. Exit 0 on approve or answer,
                                        3 on send back, 4 on expire or cancel.
      baton-mcp tools                   Print the tool schemas.
      baton-mcp doctor                  Check the store and report the paths.

    SUBMIT FLAGS
      --kind <kind>          reviewChange | openURL | approve | choose | verify | input | generic
      --priority <level>     low | normal | high | urgent
      --body <text>          Markdown detail.
      --worktree <path>      Git worktree. Baton reads the branch and head commit.
      --base <ref>           Compare from this ref to build a change summary.
      --link <url>           Repeatable.
      --choice <label>       Repeatable.
      --check <text>         Repeatable checklist item.
      --agent <name>         Agent name shown on the card.
      --session <id>         Session id.
      --timeout <seconds>    Expire the task after this long.

    ENVIRONMENT
      BATON_DB          Override the database path.
      BATON_NO_LAUNCH   Set to 1 to stop the CLI from launching the app.
      BATON_LOG         Set to 0 to disable file logging.
    """

    // MARK: - submit

    static func submit(store: TaskStore, arguments: [String]) {
        var flags = Flags(arguments)
        guard let title = flags.takePositional() else {
            fail("submit needs a title.")
        }

        let worktree = flags.value("worktree")
        let repo = worktree.flatMap { GitProbe.describe(path: $0) }
            ?? worktree.map { BatonTask.RepoRef(worktreePath: ($0 as NSString).expandingTildeInPath) }
        let base = flags.value("base")
        let summary = repo.flatMap { ref in
            base.flatMap { _ in GitProbe.changeSummary(path: ref.worktreePath, baseRef: base, headRef: nil) }
        }

        let choices = flags.values("choice").map { BatonTask.Choice(label: $0) }
        let task = BatonTask(
            kind: BatonTask.Kind(rawValue: flags.value("kind") ?? "")
                ?? ArgumentParsing.inferKind(
                    hasChoices: !choices.isEmpty,
                    hasSummary: summary != nil,
                    hasLinks: !flags.values("link").isEmpty
                ),
            priority: BatonTask.Priority(rawValue: flags.value("priority") ?? "") ?? .normal,
            title: title,
            body: flags.value("body"),
            agent: BatonTask.AgentRef(
                name: flags.value("agent") ?? "cli",
                harness: "cli",
                sessionId: flags.value("session"),
                pid: getpid()
            ),
            repo: repo,
            links: flags.values("link").map { BatonTask.Link(label: $0, url: $0) },
            choices: choices,
            checklist: flags.values("check").map { BatonTask.ChecklistItem(text: $0) },
            changeSummary: summary,
            timeoutAt: flags.value("timeout").flatMap(Double.init).map { Date().addingTimeInterval($0) },
            onTimeout: flags.value("timeout") == nil ? .wait : .proceed
        )

        do {
            let result = try store.submit(Guardrails.sanitize(task))
            WakeSignal.post()
            AppLauncher.nudge()
            print(result.task.id)
            if result.wasDeduplicated { print("(existing task returned)") }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - list

    static func list(store: TaskStore, arguments: [String]) {
        let showAll = arguments.contains("--all")
        do {
            let tasks = showAll
                ? try store.tasks()
                : try store.openTasks()
            if tasks.isEmpty {
                // stderr, so `baton-mcp list | awk '{print $1}'` yields nothing
                // instead of parsing a sentence as a task id.
                let message = showAll ? "No tasks.\n" : "No open tasks.\n"
                FileHandle.standardError.write(Data(message.utf8))
                return
            }
            for task in tasks {
                let context = task.contextLabel.map { " [\($0)]" } ?? ""
                let decision = task.response.map { " → \($0.decision.rawValue)" } ?? ""
                print("\(task.id)  \(pad(task.status.rawValue, 9))\(pad(task.priority.rawValue, 8)) \(task.title)\(context)\(decision)")
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - respond

    static func respond(store: TaskStore, arguments: [String]) {
        guard arguments.count >= 2 else { fail("respond needs an id and a decision.") }
        let id = arguments[0]
        let text = arguments.count > 2 ? arguments[2...].joined(separator: " ") : nil

        let decision: BatonTask.Response.Decision
        switch arguments[1] {
        case "approve", "approved", "ok": decision = .approved
        case "back", "reject", "sendback": decision = .sentBack
        case "answer", "answered": decision = .answered
        case "cancel", "cancelled": decision = .cancelled
        default: fail("Unknown decision '\(arguments[1])'. Use approve, back, answer, or cancel.")
        }

        do {
            guard let updated = try store.respond(id: id, response: .init(decision: decision, text: text)) else {
                fail("No task with id '\(id)'.")
            }
            WakeSignal.post()
            // Same path the app takes, so a wake hook can be tested from a shell.
            ResolveNotifier.fire(task: updated)
            print("\(updated.id) → \(updated.status.rawValue)")
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - watch

    /// Blocks until a task resolves, then reports the decision through the exit
    /// code. This lets a shell wait on a human without an MCP client:
    ///
    ///     baton-mcp watch "$ID" && git commit
    static func watch(store: TaskStore, arguments: [String]) {
        var flags = Flags(arguments)
        guard let id = flags.takePositional() else { fail("watch needs a task id.") }
        let timeout = flags.value("timeout").flatMap(Double.init) ?? 3600
        let deadline = Date().addingTimeInterval(timeout)

        guard (try? store.task(id: id)) != nil else { fail("No task with id '\(id)'.") }

        while Date() < deadline {
            _ = try? store.expireOverdue()
            guard let task = try? store.task(id: id) else { fail("Task '\(id)' disappeared.") }
            if task.status.isResolved {
                let decision = task.response?.decision ?? .cancelled
                print(decision.rawValue)
                if let text = task.response?.text, !text.isEmpty { print(text) }
                let unmet = task.response?.unmetItems ?? []
                if !unmet.isEmpty {
                    print("failed checks: " + unmet.map(\.text).joined(separator: "; "))
                }
                switch decision {
                case .approved, .answered, .chose: exit(0)
                case .sentBack: exit(3)
                case .expired, .cancelled: exit(4)
                }
            }
            usleep(300_000)
        }
        FileHandle.standardError.write(Data("timed out after \(Int(timeout))s\n".utf8))
        exit(5)
    }

    // MARK: - doctor

    static func doctor(store: TaskStore) {
        print("database   \(BatonPaths.databaseURL.path)")
        print("config     \(BatonConfig.fileURL.path)")
        print("log        \(BatonPaths.logURL.path)")
        print("bundle id  \(BatonPaths.bundleIdentifier)")
        let config = BatonConfig.load()
        if let hook = config.onResolve {
            let ready = FileManager.default.isExecutableFile(atPath: hook.command)
            print("wake hook  \(hook.command) \(ready ? "(ok)" : "(NOT EXECUTABLE)")")
        } else {
            print("wake hook  none — an agent that ended its turn will not be told")
        }
        do {
            try store.prepare()
            let open = try store.openTasks()
            let all = try store.tasks()
            print("store      ok, revision \(store.revision())")
            print("tasks      \(all.count) total, \(open.count) open")
        } catch {
            print("store      FAILED: \(error)")
            exit(1)
        }
    }

    // MARK: - Helpers

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    /// Tiny flag reader. Keeps the package free of dependencies.
    struct Flags {
        private var positionals: [String] = []
        private var pairs: [String: [String]] = [:]

        init(_ arguments: [String]) {
            var index = 0
            while index < arguments.count {
                let item = arguments[index]
                if item.hasPrefix("--") {
                    let key = String(item.dropFirst(2))
                    let next = index + 1 < arguments.count ? arguments[index + 1] : nil
                    if let next, !next.hasPrefix("--") {
                        pairs[key, default: []].append(next)
                        index += 2
                        continue
                    }
                    pairs[key, default: []].append("true")
                } else {
                    positionals.append(item)
                }
                index += 1
            }
        }

        mutating func takePositional() -> String? {
            positionals.isEmpty ? nil : positionals.removeFirst()
        }

        func value(_ key: String) -> String? { pairs[key]?.first }
        func values(_ key: String) -> [String] { pairs[key] ?? [] }
    }
}
