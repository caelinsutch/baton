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

    public init(onResolve: ResolveHook? = nil) {
        self.onResolve = onResolve
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
        /// Skip the hook when the task carries no session id, because a wake
        /// command usually cannot address an unknown session.
        public var requireSessionId: Bool

        public init(
            command: String,
            args: [String] = [],
            decisions: [String] = [],
            requireSessionId: Bool = true
        ) {
            self.command = command
            self.args = args
            self.decisions = decisions
            self.requireSessionId = requireSessionId
        }
    }

    // MARK: - Loading

    public static var fileURL: URL {
        BatonPaths.supportDirectory.appendingPathComponent("config.json")
    }

    /// Reads the config. A missing or broken file yields defaults, because a
    /// typo in a settings file must not stop you answering tasks.
    public static func load() -> BatonConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return BatonConfig() }
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(BatonConfig.self, from: data) else {
            return BatonConfig()
        }
        return config
    }

    /// Writes a commented example, so the format is discoverable.
    public static func writeExampleIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        BatonPaths.ensureSupportDirectory()
        let example = """
        {
          "_comment": [
            "Baton settings. You own this file. The MCP tools cannot write it.",
            "onResolve runs when you answer a task, so an agent that already",
            "ended its turn finds out. `command` must be an absolute path.",
            "Placeholders are substituted in `args` only.",
            "Available: {id} {sessionId} {agent} {decision} {status} {title}",
            "           {text} {worktree} {branch} {failedChecks}"
          ],
          "_example": {
            "onResolve": {
              "command": "/opt/homebrew/bin/pi",
              "args": [
                "--resume", "{sessionId}",
                "--message", "Baton: {decision}. {text} Failed checks: {failedChecks}"
              ],
              "decisions": ["approved", "sentBack", "answered", "chose"],
              "requireSessionId": true
            }
          }
        }
        """
        try? Data(example.utf8).write(to: fileURL)
    }
}
