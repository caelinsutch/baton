import Foundation
import Testing

@testable import BatonCore

/// The resolve hook is the one place Baton runs a program. These tests pin the
/// security boundary: an agent supplies data, never the command.
@Suite("ResolveNotifier")
struct ResolveNotifierTests {
    /// A script that records its arguments, so substitution is observable.
    private func makeRecorder() throws -> (script: String, output: URL, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("out.txt")
        let script = directory.appendingPathComponent("record.sh")
        let body = """
        #!/bin/bash
        printf '%s\\n' "$@" > "\(output.path)"
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, output, { try? FileManager.default.removeItem(at: directory) })
    }

    private func resolvedTask() -> BatonTask {
        var task = BatonTask(
            title: "Check the modal",
            agent: .init(name: "pi", sessionId: "sess-42"),
            repo: .init(worktreePath: "/tmp", branch: "feature/modal"),
            checklist: [
                .init(text: "Closes on Escape", checked: true),
                .init(text: "Focus returns", checked: false),
            ]
        )
        task.status = .sentBack
        task.response = .init(
            decision: .sentBack,
            text: "Focus stays on the body.",
            checklist: task.checklist
        )
        return task
    }

    /// Waits for the script to write, so the test does not race the process.
    private func waitForOutput(_ url: URL, timeout: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
            usleep(50_000)
        }
        return nil
    }

    @Test("Placeholders are replaced with task values")
    func substitution() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        let config = BatonConfig(onResolve: .init(
            command: recorder.script,
            args: ["{sessionId}", "{decision}", "{text}", "{failedChecks}", "{branch}"]
        ))
        ResolveNotifier.fire(task: resolvedTask(), config: config)

        let output = waitForOutput(recorder.output)
        let lines = (output ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 5)
        #expect(lines[0] == "sess-42")
        #expect(lines[1] == "sentBack")
        #expect(lines[2] == "Focus stays on the body.")
        // The unticked required item is the detail that saves the agent a round trip.
        #expect(lines[3] == "Focus returns")
        #expect(lines[4] == "feature/modal")
    }

    @Test("An unknown placeholder becomes empty, not literal")
    func unknownPlaceholder() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        let config = BatonConfig(onResolve: .init(command: recorder.script, args: ["a{nope}b"]))
        ResolveNotifier.fire(task: resolvedTask(), config: config)

        #expect(waitForOutput(recorder.output)?.hasPrefix("ab") == true)
    }

    @Test("A relative command never runs")
    func relativeCommandRefused() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        // A relative path would resolve against an unpredictable directory.
        let config = BatonConfig(onResolve: .init(command: "record.sh", args: ["x"]))
        ResolveNotifier.fire(task: resolvedTask(), config: config)

        #expect(waitForOutput(recorder.output, timeout: 0.5) == nil)
    }

    @Test("A non-executable command never runs")
    func nonExecutableRefused() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: recorder.script
        )

        let config = BatonConfig(onResolve: .init(command: recorder.script, args: ["x"]))
        ResolveNotifier.fire(task: resolvedTask(), config: config)

        #expect(waitForOutput(recorder.output, timeout: 0.5) == nil)
    }

    @Test("The decision filter is respected")
    func decisionFilter() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        let config = BatonConfig(onResolve: .init(
            command: recorder.script,
            args: ["{decision}"],
            decisions: ["approved"]
        ))
        // The task was sent back, so an approve-only hook must stay quiet.
        ResolveNotifier.fire(task: resolvedTask(), config: config)

        #expect(waitForOutput(recorder.output, timeout: 0.5) == nil)
    }

    @Test("A task with no session id is skipped when a session is required")
    func requiresSessionId() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        var task = resolvedTask()
        task.agent.sessionId = nil
        let config = BatonConfig(onResolve: .init(command: recorder.script, args: ["{sessionId}"]))
        ResolveNotifier.fire(task: task, config: config)

        #expect(waitForOutput(recorder.output, timeout: 0.5) == nil)
    }

    @Test("An unresolved task never fires the hook")
    func openTaskSkipped() throws {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }

        // No response set, so there is nothing to tell the agent.
        let task = BatonTask(title: "Still waiting", agent: .init(sessionId: "sess-1"))
        let config = BatonConfig(onResolve: .init(command: recorder.script, args: ["{decision}"]))
        ResolveNotifier.fire(task: task, config: config)

        #expect(waitForOutput(recorder.output, timeout: 0.5) == nil)
    }
}
