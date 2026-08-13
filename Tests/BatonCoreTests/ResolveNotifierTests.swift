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

/// `{summary}` is the placeholder the documented configs use, so its wording is
/// part of the contract with every agent that gets woken.
@Suite("ResolveNotifier summary")
struct ResolveSummaryTests {
    private func makeRecorder() throws -> (script: String, output: URL, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("out.txt")
        let script = directory.appendingPathComponent("record.sh")
        try Data("#!/bin/bash\nprintf '%s' \"$1\" > \"\(output.path)\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, output, { try? FileManager.default.removeItem(at: directory) })
    }

    private func summary(for response: BatonTask.Response, task inputTask: BatonTask? = nil) throws -> String {
        let recorder = try makeRecorder()
        defer { recorder.cleanup() }
        var task = inputTask ?? BatonTask(
            title: "Check the modal",
            agent: .init(name: "pi", sessionId: "sess-1")
        )
        task.response = response
        let config = BatonConfig(onResolve: .init(command: recorder.script, args: ["{summary}"]))
        ResolveNotifier.fire(task: task, config: config)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: recorder.output, encoding: .utf8), !text.isEmpty {
                return text
            }
            usleep(50_000)
        }
        return ""
    }

    @Test("An approval with no note reads as a clean sentence")
    func approvalWithoutNote() throws {
        let text = try summary(for: .init(decision: .approved))
        #expect(text == "The human approved \"Check the modal\".")
        // The old template left these dangling.
        #expect(!text.contains("Failed checks"))
        #expect(!text.hasSuffix(": "))
    }

    @Test("A send-back names the failed checks and says what to do")
    func sendBackWithChecks() throws {
        let items = [
            BatonTask.ChecklistItem(text: "Closes on Escape", checked: true),
            BatonTask.ChecklistItem(text: "Focus returns", checked: false),
        ]
        let text = try summary(for: .init(
            decision: .sentBack,
            text: "Focus stays on the body.",
            checklist: items
        ))
        #expect(text.contains("sent back"))
        #expect(text.contains("Focus stays on the body."))
        #expect(text.contains("Failed checks: Focus returns."))
        #expect(text.contains("submit a new Baton task"))
        // The passing check must not be reported as a failure.
        #expect(!text.contains("Closes on Escape"))
    }

    @Test("A choice reports the label, not the identifier")
    func choiceUsesLabel() throws {
        let choices = [
            BatonTask.Choice(id: "c1", label: "Redis"),
            BatonTask.Choice(id: "c2", label: "In-memory LRU"),
        ]
        var task = BatonTask(title: "Which cache?", agent: .init(sessionId: "s"), choices: choices)
        task.response = .init(decision: .chose, choiceId: "c2")
        let text = try summary(for: task.response!, task: task)
        #expect(text.contains("\"In-memory LRU\""))
        #expect(!text.contains("c2"))
    }

    @Test("An expiry tells the agent it may proceed")
    func expiry() throws {
        let text = try summary(for: .init(decision: .expired))
        #expect(text.contains("Nobody answered"))
        #expect(text.contains("own judgement"))
    }
}
