import Foundation

/// Facts about the agent that spawned this process, read from the environment.
///
/// Agents forget to pass `sessionId`, and without it a wake hook has nothing to
/// resume, so the human's answer never reaches an agent that already ended its
/// turn. Harnesses do export their session to the environment they hand an MCP
/// server, so detect it rather than trusting the model to remember.
///
/// Resolution order, first match wins:
///   1. `BATON_SESSION_ID`, `BATON_AGENT_NAME`, `BATON_HARNESS`, `BATON_MODEL`
///   2. `sessionEnvKeys` from the config file
///   3. The built-in probe table below
///   4. A generic scan for any `<PREFIX>_SESSION_ID` variable
///
/// Step 4 matters most for longevity. Only pi is verified from a real process
/// here, and harness variables change. The scan means a harness nobody has heard
/// of still works, and step 2 means a user can name the variable without waiting
/// for a code change.
public struct HarnessEnvironment: Sendable {
    public var name: String
    public var harness: String?
    public var model: String?
    public var sessionId: String?
    /// Which environment variable supplied the session, for diagnostics.
    public var sessionSource: String?

    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraSessionKeys: [String] = BatonConfig.load().sessionEnvKeys
    ) -> HarnessEnvironment {
        var harness = environment["BATON_HARNESS"].nonEmpty
        var model = environment["BATON_MODEL"].nonEmpty
        var sessionId = environment["BATON_SESSION_ID"].nonEmpty
        var sessionSource: String? = sessionId == nil ? nil : "BATON_SESSION_ID"

        // User-configured keys come before the built-ins, so an override wins.
        if sessionId == nil {
            for key in extraSessionKeys {
                if let value = environment[key].nonEmpty {
                    sessionId = value
                    sessionSource = key
                    harness = harness ?? harnessName(fromSessionKey: key)
                    break
                }
            }
        }

        if sessionId == nil, let probe = probes.first(where: { environment[$0.sessionKey].nonEmpty != nil }) {
            sessionId = environment[probe.sessionKey].nonEmpty
            sessionSource = probe.sessionKey
            harness = harness ?? probe.harness
            model = model ?? probe.modelKey.flatMap { environment[$0].nonEmpty }
        }

        if sessionId == nil, let found = scanForSessionKey(environment) {
            sessionId = found.value
            sessionSource = found.key
            harness = harness ?? harnessName(fromSessionKey: found.key)
        }

        // A harness may be identifiable even with no session available, which
        // still improves the card and the notification subtitle.
        if harness == nil {
            harness = probes.first { probe in
                probe.markerKeys.contains { environment[$0].nonEmpty != nil }
            }?.harness
        }

        let name = environment["BATON_AGENT_NAME"].nonEmpty ?? harness ?? "agent"
        return HarnessEnvironment(
            name: name,
            harness: harness,
            model: model,
            sessionId: sessionId,
            sessionSource: sessionSource
        )
    }

    public func agentRef(pid: Int32?) -> BatonTask.AgentRef {
        BatonTask.AgentRef(name: name, harness: harness, model: model, sessionId: sessionId, pid: pid)
    }

    // MARK: - Probe table

    private struct Probe: Sendable {
        let harness: String
        let sessionKey: String
        let modelKey: String?
        /// Variables that identify the harness even when no session is exported.
        let markerKeys: [String]
    }

    /// Only the pi entry is confirmed against a real process on a developer
    /// machine. The rest are best effort, and they cost nothing when absent: a
    /// missing variable simply falls through to the generic scan.
    private static let probes: [Probe] = [
        Probe(
            harness: "pi",
            sessionKey: "PI_SESSION_ID",
            modelKey: "PI_MODEL",
            markerKeys: ["PI_CODING_AGENT", "PI_SESSION_FILE", "PI_PROVIDER"]
        ),
        Probe(
            harness: "claude-code",
            sessionKey: "CLAUDE_SESSION_ID",
            modelKey: "ANTHROPIC_MODEL",
            markerKeys: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        ),
        Probe(
            harness: "codex",
            sessionKey: "CODEX_SESSION_ID",
            modelKey: "CODEX_MODEL",
            markerKeys: ["CODEX_SANDBOX", "CODEX_HOME"]
        ),
        Probe(
            harness: "cursor",
            sessionKey: "CURSOR_SESSION_ID",
            modelKey: nil,
            markerKeys: ["CURSOR_TRACE_ID", "CURSOR_AGENT"]
        ),
        Probe(
            harness: "gemini-cli",
            sessionKey: "GEMINI_SESSION_ID",
            modelKey: "GEMINI_MODEL",
            markerKeys: ["GEMINI_CLI", "GEMINI_SYSTEM_MD"]
        ),
        Probe(harness: "opencode", sessionKey: "OPENCODE_SESSION_ID", modelKey: nil, markerKeys: ["OPENCODE"]),
        Probe(harness: "windsurf", sessionKey: "WINDSURF_SESSION_ID", modelKey: nil, markerKeys: ["WINDSURF_AGENT"]),
        Probe(harness: "aider", sessionKey: "AIDER_SESSION_ID", modelKey: "AIDER_MODEL", markerKeys: ["AIDER_CHAT"]),
        Probe(harness: "cline", sessionKey: "CLINE_SESSION_ID", modelKey: nil, markerKeys: ["CLINE_AGENT"]),
        Probe(harness: "crush", sessionKey: "CRUSH_SESSION_ID", modelKey: nil, markerKeys: ["CRUSH_AGENT"]),
        Probe(harness: "amp", sessionKey: "AMP_SESSION_ID", modelKey: nil, markerKeys: ["AMP_THREAD_ID"]),
    ]

    // MARK: - Generic scan

    /// Prefixes that carry a session id for something unrelated to an agent.
    /// Picking one of these up would send a wake command to the wrong place.
    private static let ignoredPrefixes: Set<String> = [
        "BATON", "TERM", "TMUX", "SCREEN", "SSH", "XDG", "DBUS", "GNOME", "KDE",
        "ITERM", "WEZTERM", "KITTY", "ALACRITTY", "GHOSTTY", "WARP", "WINDOW",
        "AWS", "GOOGLE", "AZURE", "DOCKER", "K8S", "SYSTEMD", "LAUNCHD",
    ]

    private static func scanForSessionKey(_ environment: [String: String]) -> (key: String, value: String)? {
        let candidates = environment.keys
            .filter { $0.hasSuffix("_SESSION_ID") }
            .filter { key in
                let prefix = String(key.dropLast("_SESSION_ID".count))
                return !prefix.isEmpty && !ignoredPrefixes.contains(prefix)
            }
            // Sort so the result is deterministic when several are present.
            .sorted()

        for key in candidates {
            if let value = environment[key].nonEmpty { return (key, value) }
        }
        return nil
    }

    /// `FOO_BAR_SESSION_ID` becomes `foo-bar`.
    private static func harnessName(fromSessionKey key: String) -> String? {
        var prefix = key
        for suffix in ["_SESSION_ID", "_SESSION"] where prefix.hasSuffix(suffix) {
            prefix = String(prefix.dropLast(suffix.count))
            break
        }
        guard !prefix.isEmpty else { return nil }
        return prefix.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}

extension Optional where Wrapped == String {
    /// Treats an empty variable as absent. An exported but empty variable is a
    /// common way for a harness to mean "no value".
    var nonEmpty: String? {
        guard let value = self, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
