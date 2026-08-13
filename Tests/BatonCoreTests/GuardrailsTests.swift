import Foundation
import Testing

@testable import BatonCore

@Suite("Guardrails")
struct GuardrailsTests {
    @Test("Only safe link schemes pass")
    func schemes() {
        #expect(Guardrails.isAllowed(urlString: "http://localhost:5173"))
        #expect(Guardrails.isAllowed(urlString: "https://github.com/x/y/pull/1"))
        #expect(Guardrails.isAllowed(urlString: "vscode://file/Users/me/repo"))
        #expect(Guardrails.isAllowed(urlString: "cursor://file/Users/me/repo"))

        // A task payload comes from a model. These must never open.
        #expect(Guardrails.isAllowed(urlString: "javascript:alert(1)") == false)
        #expect(Guardrails.isAllowed(urlString: "data:text/html,<script>") == false)
        #expect(Guardrails.isAllowed(urlString: "ssh://host/repo") == false)
        #expect(Guardrails.isAllowed(urlString: "not a url") == false)
        #expect(Guardrails.isAllowed(urlString: "") == false)
    }

    @Test("Sanitising bounds every field and drops unsafe links")
    func sanitize() {
        let task = BatonTask(
            title: String(repeating: "a", count: 500),
            body: String(repeating: "b", count: 20_000),
            links: [
                .init(label: "ok", url: "https://example.com"),
                .init(label: "bad", url: "javascript:alert(1)"),
            ],
            choices: (0..<40).map { .init(label: "choice \($0)") },
            checklist: (0..<80).map { .init(text: "item \($0)") }
        )

        let clean = Guardrails.sanitize(task)

        #expect(clean.title.count == Guardrails.maxTitleLength)
        #expect((clean.body?.count ?? 0) == Guardrails.maxBodyLength)
        #expect(clean.links.map(\.label) == ["ok"])
        #expect(clean.choices.count == Guardrails.maxChoices)
        #expect(clean.checklist.count == Guardrails.maxChecklistItems)
    }

    @Test("An empty title becomes a placeholder instead of an empty card")
    func emptyTitle() {
        let clean = Guardrails.sanitize(BatonTask(title: "   "))
        #expect(clean.title == "Untitled task")
    }

    @Test("A burst of submits hits the rate limit")
    func rateLimit() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-rate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TaskStore(path: directory.appendingPathComponent("tasks.db").path)
        for index in 0..<Guardrails.submitsPerMinute {
            _ = try store.submit(BatonTask(
                title: "task \(index)",
                agent: .init(name: "loop", sessionId: "sess")
            ))
        }

        #expect(throws: Guardrails.Violation.self) {
            try Guardrails.checkRate(store: store, sessionId: "sess")
        }
        // A different session must not be punished for another one's loop.
        #expect(throws: Never.self) {
            try Guardrails.checkRate(store: store, sessionId: "other")
        }
    }
}

@Suite("ULID")
struct ULIDTests {
    @Test("Identifiers sort by creation order")
    func monotonic() {
        let ids = (0..<500).map { _ in ULID.generate() }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 26 })
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Round trip keeps types")
    func roundTrip() throws {
        let value = JSONValue.object([
            "id": "abc",
            "count": 3,
            "ok": true,
            "nested": .object(["list": .array([1, 2, 3])]),
        ])
        let parsed = try JSONValue.parse(value.serialized())
        #expect(parsed["id"]?.stringValue == "abc")
        #expect(parsed["count"]?.intValue == 3)
        #expect(parsed["ok"]?.boolValue == true)
        #expect(parsed["nested"]?["list"]?.arrayValue?.count == 3)
    }

    @Test("Whole numbers do not gain a decimal point")
    func integerFormatting() {
        // An id rendered as "3.0" breaks a client that expects an integer.
        let text = JSONValue.object(["count": 3]).compactString()
        #expect(text.contains("\"count\":3"))
    }

    @Test("Compacting drops nil and null entries")
    func compacting() {
        let value = JSONValue.object(compacting: [
            "present": .string("yes"),
            "absent": nil,
            "explicitNull": .null,
        ])
        #expect(value.objectValue?.keys.sorted() == ["present"])
    }

    @Test("A JSON null reads as absent")
    func nullSubscript() throws {
        let parsed = try JSONValue.parse(#"{"a":null,"b":1}"#)
        #expect(parsed["a"] == nil)
        #expect(parsed["b"]?.intValue == 1)
    }
}
