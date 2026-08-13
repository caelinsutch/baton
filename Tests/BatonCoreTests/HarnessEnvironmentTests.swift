import Foundation
import Testing

@testable import BatonCore

/// Session detection decides whether a wake hook can reach an agent at all, so
/// the fallback chain is worth pinning down.
@Suite("HarnessEnvironment")
struct HarnessEnvironmentTests {
    @Test("An explicit BATON_SESSION_ID wins over everything")
    func explicitWins() {
        let result = HarnessEnvironment.detect(
            environment: [
                "BATON_SESSION_ID": "explicit",
                "BATON_AGENT_NAME": "my-agent",
                "BATON_HARNESS": "custom",
                "PI_SESSION_ID": "pi-session",
            ],
            extraSessionKeys: []
        )
        #expect(result.sessionId == "explicit")
        #expect(result.name == "my-agent")
        #expect(result.harness == "custom")
    }

    @Test("pi is detected from its own variables")
    func detectsPi() {
        let result = HarnessEnvironment.detect(
            environment: [
                "PI_SESSION_ID": "019ffbcf-615c-787d-a936-c44137c13849",
                "PI_MODEL": "us.anthropic.claude-opus-5",
            ],
            extraSessionKeys: []
        )
        #expect(result.harness == "pi")
        #expect(result.sessionId == "019ffbcf-615c-787d-a936-c44137c13849")
        #expect(result.model == "us.anthropic.claude-opus-5")
        // The card should say "pi", not a generic placeholder.
        #expect(result.name == "pi")
        #expect(result.sessionSource == "PI_SESSION_ID")
    }

    @Test("A configured key is tried before the built-in table")
    func configuredKeyWins() {
        let result = HarnessEnvironment.detect(
            environment: ["MY_TOOL_SESSION": "abc", "PI_SESSION_ID": "pi"],
            extraSessionKeys: ["MY_TOOL_SESSION"]
        )
        #expect(result.sessionId == "abc")
        #expect(result.harness == "my-tool")
    }

    @Test("An unknown harness is found by the generic scan")
    func genericScan() {
        // This is the case that keeps Baton working as harnesses come and go.
        let result = HarnessEnvironment.detect(
            environment: ["SOME_NEW_AGENT_SESSION_ID": "xyz"],
            extraSessionKeys: []
        )
        #expect(result.sessionId == "xyz")
        #expect(result.harness == "some-new-agent")
        #expect(result.sessionSource == "SOME_NEW_AGENT_SESSION_ID")
    }

    @Test("Unrelated session variables are ignored")
    func ignoresUnrelated() {
        // Waking an agent from a terminal's session id would be worse than not
        // waking one at all.
        let result = HarnessEnvironment.detect(
            environment: [
                "TERM_SESSION_ID": "w0t0p0",
                "ITERM_SESSION_ID": "w0t1p0",
                "SSH_SESSION_ID": "nope",
                "AWS_SESSION_ID": "nope",
            ],
            extraSessionKeys: []
        )
        #expect(result.sessionId == nil)
        #expect(result.harness == nil)
        #expect(result.name == "agent")
    }

    @Test("The scan is deterministic when several candidates exist")
    func deterministicScan() {
        let environment = ["ZED_SESSION_ID": "z", "AIDER_SESSION_ID": "a"]
        // Aider is in the probe table, so it is chosen before any scan happens.
        let result = HarnessEnvironment.detect(environment: environment, extraSessionKeys: [])
        #expect(result.harness == "aider")

        // With no known probe, sorting keeps repeated runs consistent.
        let unknown = HarnessEnvironment.detect(
            environment: ["BRAVO_SESSION_ID": "b", "ALPHA_SESSION_ID": "a"],
            extraSessionKeys: []
        )
        #expect(unknown.sessionId == "a")
    }

    @Test("A harness is named even when it exports no session")
    func markerOnly() {
        // Claude Code exports CLAUDECODE but may not export a session id. Naming
        // the harness still improves the card and the notification subtitle.
        let result = HarnessEnvironment.detect(
            environment: ["CLAUDECODE": "1"],
            extraSessionKeys: []
        )
        #expect(result.harness == "claude-code")
        #expect(result.name == "claude-code")
        #expect(result.sessionId == nil)
    }

    @Test("An empty variable counts as absent")
    func emptyIsAbsent() {
        let result = HarnessEnvironment.detect(
            environment: ["BATON_SESSION_ID": "   ", "PI_SESSION_ID": "real"],
            extraSessionKeys: []
        )
        #expect(result.sessionId == "real")
    }

    @Test("The agent reference carries the pid for liveness checks")
    func agentRef() {
        let result = HarnessEnvironment.detect(environment: ["PI_SESSION_ID": "s"], extraSessionKeys: [])
        let ref = result.agentRef(pid: 4321)
        #expect(ref.pid == 4321)
        #expect(ref.sessionId == "s")
        #expect(ref.harness == "pi")
    }
}
