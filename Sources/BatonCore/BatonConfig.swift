import Foundation

/// Settings the human controls, at
/// `~/Library/Application Support/dev.baton/config.json`.
///
/// This file is deliberately not writable through the MCP tools. An agent must
/// never be able to influence what Baton runs on your machine.
public struct BatonConfig: Codable, Sendable {
    /// What to run when a task resolves, so an agent that already ended its turn
    /// finds out.
    public var onResolve: ResolveHook?

    /// Extra environment variables that hold an agent session id, tried before the
    /// built-in list.
    ///
    /// Harness variable names change and Baton cannot verify every one, so this
    /// lets you name yours without waiting for a release.
    public var sessionEnvKeys: [String]

    public init(onResolve: ResolveHook? = nil, sessionEnvKeys: [String] = []) {
        self.onResolve = onResolve
        self.sessionEnvKeys = sessionEnvKeys
    }

    // Both fields are optional in the file, so an older config keeps working.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onResolve = try container.decodeIfPresent(ResolveHook.self, forKey: .onResolve)
        sessionEnvKeys = try container.decodeIfPresent([String].self, forKey: .sessionEnvKeys) ?? []
    }

    /// A command template.
    ///
    /// Baton substitutes placeholders in `args` only. The executable itself is
    /// fixed by you, so a task payload can never choose the program that runs.
    ///
    /// Placeholders: `{id}`, `{sessionId}`, `{agent}`, `{decision}`, `{status}`,
    /// `{title}`, `{text}`, `{worktree}`, `{branch}`, `{failedChecks}`.
    public struct ResolveHook: Codable, Sendable {
        /// Absolute path to the program. No shell, no PATH lookup, no arguments.
        public var command: String
        public var args: [String]
        /// Only fire for these decisions. Empty means all of them.
        public var decisions: [String]
        /// Skip the hook when the task carries no session id.
        ///
        /// Set this only if your command addresses a session by id. Harnesses that
        /// resume "the last session in this directory", such as `pi --continue`,
        /// do not need one, and requiring it would silently disable the hook.
        public var requireSessionId: Bool

        /// Skip the hook when the task has no existing worktree.
        ///
        /// Essential for a directory-based resume. The hook runs with the worktree
        /// as its working directory; without one it would inherit the app's
        /// directory and `--continue` would wake whatever unrelated session happens
        /// to be newest there. Waking the wrong agent is worse than waking none.
        public var requireWorktree: Bool

        public init(
            command: String,
            args: [String] = [],
            decisions: [String] = [],
            requireSessionId: Bool = true,
            requireWorktree: Bool = false
        ) {
            self.command = command
            self.args = args
            self.decisions = decisions
            self.requireSessionId = requireSessionId
            self.requireWorktree = requireWorktree
        }

        // Both flags are optional in the file.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
            requireSessionId = try container.decodeIfPresent(Bool.self, forKey: .requireSessionId) ?? true
            requireWorktree = try container.decodeIfPresent(Bool.self, forKey: .requireWorktree) ?? false
        }
    }

    // MARK: - Loading

    public static var fileURL: URL {
        BatonPaths.supportDirectory.appendingPathComponent("config.json")
    }

    private static let cache = Cache()

    /// Reads the config, cached for the life of the process.
    ///
    /// A missing or broken file yields defaults, because a typo in a settings file
    /// must not stop you answering tasks. The cache matters because this is read on
    /// every submit, and a disk read per tool call is waste.
    public static func load() -> BatonConfig {
        cache.value()
    }

    /// Drops the cache, so a test or a settings change takes effect.
    public static func reload() {
        cache.clear()
    }

    private static func readFromDisk() -> BatonConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return BatonConfig() }
        guard let config = try? JSONDecoder().decode(BatonConfig.self, from: data) else {
            return BatonConfig()
        }
        return config
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: BatonConfig?

        func value() -> BatonConfig {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return stored }
            let loaded = BatonConfig.readFromDisk()
            stored = loaded
            return loaded
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            stored = nil
        }
    }

    /// Writes a commented example, so the format is discoverable.
    public static func writeExampleIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        BatonPaths.ensureSupportDirectory()
        let example = """
        {
          "_comment": [
            "Baton settings. You own this file. The MCP tools cannot write it.",
            "",
            "onResolve runs when you answer a task, so an agent that already ended",
            "its turn finds out. An agent still blocked inside ask_human or",
            "await_task does not need this: it polls and sees your answer in under",
            "a second.",
            "",
            "`command` must be an absolute path to an executable. Baton runs it",
            "directly, with no shell, from the task's worktree. Placeholders are",
            "substituted in `args` only, so a task payload supplies data and never",
            "the program.",
            "",
            "Placeholders: {summary} {id} {sessionId} {agent} {decision} {status}",
            "              {title} {text} {worktree} {branch} {failedChecks}",
            "",
            "Prefer {summary}. It is a complete sentence that already handles the",
            "empty cases, so an approval with no note does not produce dangling",
            "labels like 'approved on \\"X\\":  Failed checks:'.",
            "",
            "sessionEnvKeys adds environment variables that hold an agent session",
            "id. Note that some harnesses do not pass their session to an MCP",
            "server at all, in which case a directory-based resume like the pi",
            "example below is the reliable option."
          ],

          "_example_pi": {
            "onResolve": {
              "command": "/opt/homebrew/bin/pi",
              "args": [
                "--continue",
                "--print",
                "{summary}"
              ],
              "decisions": ["approved", "sentBack", "answered", "chose"],
              "requireSessionId": false,
              "requireWorktree": true
            }
          },

          "_example_by_session_id": {
            "onResolve": {
              "command": "/opt/homebrew/bin/pi",
              "args": ["--session-id", "{sessionId}", "--print", "{summary}"],
              "requireSessionId": true
            },
            "sessionEnvKeys": ["MY_AGENT_SESSION"]
          }
        }
        """
        try? Data(example.utf8).write(to: fileURL)
    }
}
