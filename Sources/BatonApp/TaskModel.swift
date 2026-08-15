import BatonCore
import Combine
import Foundation
import Observation

/// The app's single source of view state.
///
/// The store on disk stays authoritative. This class reloads on a wake signal
/// and on a slow timer, so a missed signal costs one poll interval instead of a
/// lost task.
@MainActor
@Observable
final class TaskModel {
    private(set) var openTasks: [BatonTask] = []
    private(set) var recentlyResolved: [BatonTask] = []
    var phase: NotchPhase = .closed

    /// Draft text for the send-back note, keyed by task id.
    var noteDrafts: [String: String] = [:]
    /// Chosen option, before the human confirms.
    var choiceDrafts: [String: String] = [:]
    /// True while the send-back note field is open.
    var isComposingNote = false

    /// True when the human opened the shell deliberately, by clicking it or by
    /// pressing a shortcut.
    ///
    /// Focus follows this rather than the phase. A task arriving must never take
    /// the keyboard, but once you reach for the notch you expect Escape to close it
    /// and the shortcuts to work, so at that point it should hold focus like any
    /// normal window.
    var wantsFocus = false

    var lastError: String?

    private let store: TaskStore
    private var wakeToken: WakeSignal.Token?
    private var pollTimer: Timer?
    private var peekTimer: Timer?
    private var closeTimer: Timer?
    private var knownIds: Set<String> = []
    private var lastRevision: Int64 = -1

    /// Called when a task appears, so the app can notify. Set by the delegate.
    var onNewTask: ((BatonTask) -> Void)?
    /// Called when a task resolves, so a stale notification can be withdrawn.
    var onTaskResolved: ((BatonTask) -> Void)?

    init(store: TaskStore = TaskStore()) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try store.prepare()
        } catch {
            lastError = "Baton cannot open its database: \(error)"
        }
        // Treat everything already in the store as known, so a restart does not
        // replay old notifications.
        knownIds = Set((try? store.openTasks())?.map(\.id) ?? [])
        reload(announce: false)

        wakeToken = WakeSignal.observe { [weak self] in
            self?.reload()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stop() {
        wakeToken = nil
        pollTimer?.invalidate()
        peekTimer?.invalidate()
        closeTimer?.invalidate()
    }

    // MARK: - Loading

    func reload(announce: Bool = true) {
        let revision = store.revision()
        // Expiry is time-based, so check it even when nothing was written.
        if let expired = try? store.expireOverdue(), !expired.isEmpty {
            for task in expired {
                onTaskResolved?(task)
                // An expired task is a resolution too. An agent told to proceed
                // on timeout needs to hear that it may proceed.
                ResolveNotifier.fire(task: task)
            }
        } else if revision == lastRevision, !openTasks.isEmpty {
            return
        }
        lastRevision = revision

        let previous = openTasks
        do {
            openTasks = try store.openTasks()
            recentlyResolved = try store.tasks(statuses: [.done, .sentBack, .expired, .cancelled], limit: 20)
                .sorted { ($0.respondedAt ?? $0.updatedAt) > ($1.respondedAt ?? $1.updatedAt) }
        } catch {
            lastError = "Baton cannot read its database: \(error)"
            return
        }

        // Tell the delegate about tasks that other processes resolved, so it can
        // pull their notifications.
        let openIds = Set(openTasks.map(\.id))
        for task in previous where !openIds.contains(task.id) {
            onTaskResolved?(task)
        }

        guard announce else {
            knownIds = openIds
            syncPhaseAfterReload()
            return
        }

        let arrived = openTasks.filter { !knownIds.contains($0.id) && $0.isVisible() }
        knownIds = openIds
        for task in arrived {
            onNewTask?(task)
        }
        // Show the newest arrival, but never interrupt work already in progress.
        if let newest = arrived.last, !isBusy {
            // With the expand marker set, the card opens straight away. Hover is
            // awkward to drive from a script, and the card is what you usually
            // want while working on the views.
            if Trace.autoExpand {
                setPhase(.expanded(newest.id))
            } else {
                peek(taskId: newest.id)
            }
        } else {
            syncPhaseAfterReload()
        }
    }

    /// True while the human is mid-task and must not be yanked away.
    private var isBusy: Bool {
        if isComposingNote { return true }
        switch phase {
        case .working, .expanded: return true
        // A closing notch is not busy. An arriving task should interrupt it.
        case .closed, .idle, .peek, .queue, .allClear: return false
        }
    }

    /// Drops the phase back to something valid after the task list changes.
    private func syncPhaseAfterReload() {
        // The shown task may have been resolved somewhere else: the agent called
        // cancel_task, a deadline passed, or another surface answered it. Checking
        // `task(id:)` is not enough, because that also finds resolved tasks in the
        // recent list, which left an answered card sitting on screen.
        if let id = phase.taskId, !openTasks.contains(where: { $0.id == id && $0.isVisible() }) {
            if visibleTasks.isEmpty {
                finishAndClose()
            } else {
                setPhase(.idle)
            }
            return
        }
        if phase == .closed, !visibleTasks.isEmpty {
            setPhase(.idle)
            return
        }
        if visibleTasks.isEmpty, phase == .idle {
            // Fade out rather than blink away.
            finishAndClose()
        }
    }

    // MARK: - Derived state

    /// Open tasks that are not snoozed into the future.
    var visibleTasks: [BatonTask] {
        openTasks.filter { $0.isVisible() }
    }

    var pendingCount: Int { visibleTasks.count }

    var topPriority: BatonTask.Priority? {
        visibleTasks.map(\.priority).max()
    }

    var currentTask: BatonTask? {
        phase.taskId.flatMap { task(id: $0) }
    }

    func task(id: String) -> BatonTask? {
        openTasks.first { $0.id == id } ?? recentlyResolved.first { $0.id == id }
    }

    /// Tasks grouped by worktree, which is how you actually think about them
    /// when several agents run at once.
    var groupedByWorktree: [(label: String, tasks: [BatonTask])] {
        let groups = Dictionary(grouping: visibleTasks) { task -> String in
            task.repo?.branch ?? task.repo?.folderName ?? task.agent.name
        }
        return groups
            .map { (label: $0.key, tasks: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { lhs, rhs in
                let left = lhs.tasks.map(\.priority).max() ?? .low
                let right = rhs.tasks.map(\.priority).max() ?? .low
                if left != right { return left > right }
                return lhs.label < rhs.label
            }
    }

    // MARK: - Phase control

    func setPhase(_ next: NotchPhase) {
        guard phase != next else { return }
        peekTimer?.invalidate()
        // Focus is only ever held by an open surface.
        if next.isCollapsed || next == .closed {
            wantsFocus = false
        }
        // A new phase cancels a pending close, so an arriving task interrupts the
        // goodbye rather than racing it.
        if next != .closed { closeTimer?.invalidate() }
        if next.taskId == nil || next.taskId != phase.taskId {
            isComposingNote = false
        }
        phase = next
    }

    /// Shows a task briefly, then collapses. Hovering cancels the collapse.
    func peek(taskId: String) {
        setPhase(.peek(taskId))
        peekTimer = Timer.scheduledTimer(withTimeInterval: Motion.peekDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .peek(let current) = self.phase, current == taskId else { return }
                self.setPhase(self.visibleTasks.isEmpty ? .closed : .idle)
            }
        }
    }

    func cancelPeekCollapse() {
        peekTimer?.invalidate()
    }

    /// Opens the shell from a click on the pill.
    ///
    /// Hover alone was not enough. Pointing at a 30 point pill under the menu bar
    /// is fiddly, and a click is what most people try first.
    func openFromShell() {
        // Peek counts too. A task has just slid in and you reach for it, which is
        // the most likely moment anyone clicks the notch at all.
        switch phase {
        case .idle, .peek:
            hoverBegan()
            // A click is a deliberate gesture, so the shell may take the keyboard.
            wantsFocus = true
        case .closed, .expanded, .working, .queue, .allClear:
            break
        }
    }

    /// Hover expands from the pill. Never collapses an open card.
    func hoverBegan() {
        cancelPeekCollapse()
        switch phase {
        case .idle:
            setPhase(visibleTasks.count == 1 ? .expanded(visibleTasks[0].id) : .queue)
        case .peek(let id):
            setPhase(.expanded(id))
        case .closed, .expanded, .working, .queue, .allClear:
            break
        }
    }

    func hoverEnded() {
        // Collapse only from the shallow states. An expanded card stays until
        // the human dismisses it, so the pointer can leave to click a link.
        if case .peek = phase {
            setPhase(visibleTasks.isEmpty ? .closed : .idle)
        }
    }

    func dismiss() {
        if isComposingNote {
            isComposingNote = false
            return
        }
        switch phase {
        case .expanded(let id), .peek(let id):
            // A started task keeps its bar, so you do not lose the checklist.
            if task(id: id)?.status == .active {
                setPhase(.working(id))
            } else {
                setPhase(visibleTasks.isEmpty ? .closed : .idle)
            }
        case .queue, .working:
            setPhase(visibleTasks.isEmpty ? .closed : .idle)
        case .closed, .idle, .allClear:
            break
        }
    }

    /// One deliberate open-or-close, for the shortcut and the menu bar.
    ///
    /// This replaced a pair of calls that each toggled, so the shortcut fired,
    /// opened the queue, and immediately closed it again. Net effect: the key
    /// appeared dead.
    ///
    /// It also picks the right surface. Sending you to a list to read a single task
    /// is a wasted step.
    func toggleOpen() {
        switch phase {
        case .expanded, .queue:
            dismiss()
        case .closed, .idle, .peek, .working, .allClear:
            guard let first = visibleTasks.first else { return }
            setPhase(visibleTasks.count == 1 ? .expanded(first.id) : .queue)
            wantsFocus = true
        }
    }

    /// The task the human can currently see, if any.
    ///
    /// Acting on `visibleTasks.first` instead would let a shortcut approve
    /// something that is not on screen, which is the one thing an approval
    /// shortcut must never do.
    var onScreenTaskId: String? {
        switch phase {
        case .expanded(let id), .working(let id), .peek(let id): return id
        case .closed, .idle, .queue, .allClear: return nil
        }
    }

    func open(taskId: String) {
        setPhase(.expanded(taskId))
    }

    /// Opens a task from a shortcut or a notification, which are both deliberate.
    func openWithFocus(taskId: String) {
        setPhase(.expanded(taskId))
        wantsFocus = true
    }

    /// Called when Baton stops being the active app, which means you clicked
    /// somewhere else.
    ///
    /// An open card had no way out: Escape needed focus it did not have, hover-out
    /// deliberately does not collapse it, and there was no close control. Treating
    /// a click elsewhere as "I am done looking" is what every popover does.
    func resignedActive() {
        guard case .expanded(let id) = phase else {
            if phase == .queue { setPhase(visibleTasks.isEmpty ? .closed : .idle) }
            return
        }
        // Keep the checklist to hand. You probably clicked away to go and check it.
        if let task = task(id: id), !task.checklist.isEmpty {
            setPhase(.working(id))
        } else {
            setPhase(visibleTasks.isEmpty ? .closed : .idle)
        }
    }

    // MARK: - Actions

    /// Marks the task in progress and switches to the slim working bar, so the
    /// human can go to another app and still see what to check.
    func start(taskId: String) {
        mutate(taskId) { $0.status = .active }
        setPhase(.working(taskId))
    }

    func approve(taskId: String) {
        respond(taskId, decision: .approved)
    }

    func sendBack(taskId: String) {
        let note = noteDrafts[taskId]?.trimmingCharacters(in: .whitespacesAndNewlines)
        respond(taskId, decision: .sentBack, text: note?.isEmpty == false ? note : "Sent back without a note.")
    }

    func answer(taskId: String) {
        let note = noteDrafts[taskId]?.trimmingCharacters(in: .whitespacesAndNewlines)
        respond(taskId, decision: .answered, text: note)
    }

    func choose(taskId: String, choiceId: String) {
        choiceDrafts[taskId] = choiceId
        respond(taskId, decision: .chose, choiceId: choiceId)
    }

    /// The confirm button changes meaning with the kind of task.
    func confirm(taskId: String) {
        Trace.log("confirm task=\(taskId)")
        guard let task = task(id: taskId) else { return }
        switch task.kind {
        case .choose:
            guard let choiceId = choiceDrafts[taskId] else { return }
            choose(taskId: taskId, choiceId: choiceId)
        case .input:
            answer(taskId: taskId)
        default:
            approve(taskId: taskId)
        }
    }

    func snooze(taskId: String, minutes: Int = 15) {
        mutate(taskId) { task in
            task.status = .snoozed
            task.snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
        setPhase(visibleTasks.isEmpty ? .closed : .idle)
    }

    /// Ticks go straight to the store.
    ///
    /// Holding them in memory loses your work: you tick three of five checks,
    /// close the card or restart the app, and they are gone. A tick is a real
    /// observation about the world, so it is worth a write.
    func toggleChecklistItem(taskId: String, itemId: String) {
        mutate(taskId) { task in
            guard let index = task.checklist.firstIndex(where: { $0.id == itemId }) else { return }
            task.checklist[index].checked.toggle()
        }
    }

    func isChecked(taskId: String, item: BatonTask.ChecklistItem) -> Bool {
        task(id: taskId)?.checklist.first { $0.id == item.id }?.checked ?? item.checked
    }

    private func respond(
        _ taskId: String,
        decision: BatonTask.Response.Decision,
        text: String? = nil,
        choiceId: String? = nil,
        caller: String = #function
    ) {
        Trace.log("respond \(decision.rawValue) task=\(taskId) from=\(caller)")
        guard let task = task(id: taskId) else { return }
        let response = BatonTask.Response(
            decision: decision,
            text: text,
            choiceId: choiceId,
            checklist: task.checklist
        )
        let resolved: BatonTask?
        do {
            resolved = try store.respond(id: taskId, response: response)
            WakeSignal.post()
        } catch {
            lastError = "Baton cannot save the answer: \(error)"
            return
        }
        // A blocked agent polls and sees this within about a second. An agent
        // that already ended its turn needs a push, which is what the hook does.
        if let resolved {
            ResolveNotifier.fire(task: resolved)
        }
        noteDrafts[taskId] = nil
        choiceDrafts[taskId] = nil
        isComposingNote = false
        reload(announce: false)
        // Move to the next task instead of collapsing, so a queue drains fast.
        if let next = visibleTasks.first {
            setPhase(visibleTasks.count == 1 ? .expanded(next.id) : .queue)
        } else {
            finishAndClose()
        }
    }

    /// Ends on a confirmation beat.
    ///
    /// Dropping straight to `.closed` made the last approval look broken: the card
    /// collapsed toward a tiny pill and the window was pulled at the same moment.
    /// Holding a short "All clear" pill gives the collapse somewhere to land.
    private func finishAndClose() {
        setPhase(.allClear)
        closeTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .allClear else { return }
                self.setPhase(.closed)
            }
        }
    }

    private func mutate(_ taskId: String, _ change: @escaping (inout BatonTask) -> Void) {
        do {
            _ = try store.mutate(id: taskId, change)
            WakeSignal.post()
            reload(announce: false)
        } catch {
            lastError = "Baton cannot update the task: \(error)"
        }
    }
}
