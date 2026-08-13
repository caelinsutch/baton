import Foundation
import Testing

@testable import BatonCore

/// The store is the contract between the app and every agent process, so these
/// tests cover the parts that would silently corrupt that contract.
@Suite("TaskStore")
struct TaskStoreTests {
    /// A fresh database per test. Tests must not share state through a file.
    private func makeStore() -> (TaskStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tasks.db")
        return (TaskStore(path: url.path), directory)
    }

    @Test("A submitted task comes back as pending")
    func submitAndRead() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = BatonTask(title: "Review the auth change")
        let result = try store.submit(task)

        #expect(result.wasDeduplicated == false)
        let loaded = try store.task(id: task.id)
        #expect(loaded?.title == "Review the auth change")
        #expect(loaded?.status == .pending)
        #expect(try store.openTasks().count == 1)
    }

    @Test("A repeated dedupeKey returns the existing task")
    func dedupe() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.submit(BatonTask(title: "Ask once", dedupeKey: "key-1"))
        let second = try store.submit(BatonTask(title: "Ask again", dedupeKey: "key-1"))

        #expect(second.wasDeduplicated)
        #expect(second.task.id == first.task.id)
        #expect(try store.openTasks().count == 1)
    }

    @Test("A resolved task frees its dedupeKey")
    func dedupeAfterResolve() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.submit(BatonTask(title: "Ask once", dedupeKey: "key-1"))
        _ = try store.respond(id: first.task.id, response: .init(decision: .approved))

        // The same question may be worth asking again after a change.
        let second = try store.submit(BatonTask(title: "Ask once", dedupeKey: "key-1"))
        #expect(second.wasDeduplicated == false)
        #expect(second.task.id != first.task.id)
    }

    @Test("A response closes the task and keeps the checklist")
    func respondStoresChecklist() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let items = [
            BatonTask.ChecklistItem(text: "Modal closes"),
            BatonTask.ChecklistItem(text: "Focus returns"),
        ]
        let task = BatonTask(title: "Check the modal", checklist: items)
        _ = try store.submit(task)

        var reported = items
        reported[0].checked = true
        let updated = try store.respond(
            id: task.id,
            response: .init(decision: .sentBack, text: "Focus stays on the body.", checklist: reported)
        )

        #expect(updated?.status == .sentBack)
        #expect(updated?.response?.text == "Focus stays on the body.")
        // The failed item is what tells the agent where to look.
        #expect(updated?.response?.unmetItems.map(\.text) == ["Focus returns"])
        #expect(try store.openTasks().isEmpty)
    }

    @Test("An overdue task expires only when the policy allows it")
    func expiry() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let past = Date().addingTimeInterval(-10)
        let waiting = BatonTask(title: "Wait forever", timeoutAt: past, onTimeout: .wait)
        let proceeding = BatonTask(title: "Proceed alone", timeoutAt: past, onTimeout: .proceed)
        _ = try store.submit(waiting)
        _ = try store.submit(proceeding)

        let expired = try store.expireOverdue()

        #expect(expired.map(\.id) == [proceeding.id])
        #expect(try store.task(id: waiting.id)?.status == .pending)
        #expect(try store.task(id: proceeding.id)?.status == .expired)
    }

    @Test("A snoozed task stays open but leaves the visible queue")
    func snooze() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = BatonTask(title: "Later")
        _ = try store.submit(task)
        _ = try store.mutate(id: task.id) { item in
            item.status = .snoozed
            item.snoozedUntil = Date().addingTimeInterval(900)
        }

        let open = try store.openTasks()
        #expect(open.count == 1)
        #expect(open[0].isVisible() == false)
    }

    @Test("Open tasks sort urgent first, then oldest")
    func ordering() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = BatonTask(createdAt: Date().addingTimeInterval(-60), title: "Old normal")
        let new = BatonTask(title: "New normal")
        let urgent = BatonTask(priority: .urgent, title: "Urgent")
        _ = try store.submit(old)
        _ = try store.submit(new)
        _ = try store.submit(urgent)

        #expect(try store.openTasks().map(\.title) == ["Urgent", "Old normal", "New normal"])
    }

    @Test("The revision counter grows on every write")
    func revisionChanges() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.prepare()
        let before = store.revision()
        _ = try store.submit(BatonTask(title: "Something"))
        #expect(store.revision() > before)
    }

    @Test("A second connection sees the first connection's writes")
    func crossProcessVisibility() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = BatonTask(title: "Written by the agent")
        _ = try store.submit(task)

        // A separate TaskStore stands in for the app process.
        let reader = TaskStore(path: directory.appendingPathComponent("tasks.db").path)
        #expect(try reader.task(id: task.id)?.title == "Written by the agent")

        // And the app's answer must reach the agent's connection.
        _ = try reader.respond(id: task.id, response: .init(decision: .approved))
        #expect(try store.task(id: task.id)?.status == .done)
    }

    @Test("Pruning removes resolved tasks and keeps open ones")
    func prune() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let open = BatonTask(title: "Still waiting")
        let closed = BatonTask(title: "Finished")
        _ = try store.submit(open)
        _ = try store.submit(closed)
        _ = try store.respond(id: closed.id, response: .init(decision: .approved))

        let removed = try store.pruneResolved(olderThan: -1)
        #expect(removed == 1)
        #expect(try store.task(id: open.id) != nil)
        #expect(try store.task(id: closed.id) == nil)
    }
}
