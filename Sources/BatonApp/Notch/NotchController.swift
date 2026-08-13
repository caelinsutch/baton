import AppKit
import BatonCore
import SwiftUI

/// Owns the notch panel: creates it, tracks the display, keeps the hit area in
/// sync with the shell, and hides the panel when the queue is empty.
@MainActor
final class NotchController {
    private let model: TaskModel
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var contentView: PassthroughView?
    private var metrics: NotchMetrics?
    private var screenObserver: NSObjectProtocol?
    private var phaseObservation: NSKeyValueObservation?

    init(model: TaskModel) {
        self.model = model
    }

    func start() {
        rebuild()
        // The notch moves when you plug in a display or change the arrangement.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        observePhase()
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Building

    private func rebuild() {
        guard let screen = NotchMetrics.preferredScreen() else { return }
        let metrics = NotchMetrics.measure(screen: screen)
        Trace.log("rebuild screen=\(screen.frame) metrics=\(metrics) panelFrame=\(metrics.panelFrame)")
        self.metrics = metrics

        let panel = self.panel ?? makePanel(frame: metrics.panelFrame)
        panel.setFrame(metrics.panelFrame, display: false)

        let root = NotchRootView(model: model, metrics: metrics) { [weak self] frame in
            self?.updateHitArea(frame)
        }
        if let hostingView {
            hostingView.rootView = AnyView(root)
        } else {
            let hosting = NSHostingView(rootView: AnyView(root))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            let container = PassthroughView(frame: panel.contentLayoutRect)
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            panel.contentView = container
            hostingView = hosting
            contentView = container
        }

        self.panel = panel
        applyVisibility()
    }

    private func makePanel(frame: CGRect) -> NotchPanel {
        let panel = NotchPanel(frame: frame)
        panel.onCancel = { [weak self] in
            Task { @MainActor in self?.model.dismiss() }
        }
        return panel
    }

    // MARK: - Hit area

    /// SwiftUI reports the shell frame in the panel's coordinate space, measured
    /// from the top left. `PassthroughView` is flipped to match, so the rect
    /// needs no conversion. Anything outside it passes clicks through.
    private func updateHitArea(_ shellFrame: CGRect) {
        guard let contentView else { return }
        // A few points of slack, so a click on the very edge of the glass lands.
        contentView.interactiveRect = shellFrame.insetBy(dx: -4, dy: -4)
    }

    // MARK: - Visibility and focus

    private func observePhase() {
        // `withObservationTracking` fires once, so re-arm it after every change.
        withObservationTracking {
            _ = model.phase
            _ = model.pendingCount
            _ = model.isComposingNote
        } onChange: {
            Task { @MainActor [weak self] in
                self?.applyVisibility()
                self?.observePhase()
            }
        }
    }

    /// Shows or hides the panel, then settles focus.
    ///
    /// Focus is the subtle part. A borderless nonactivating panel can become key
    /// while its app stays in the background, which means your editor still looks
    /// focused while your keystrokes go somewhere else. So the rule here is:
    /// take key only for a text surface, and when we do, activate the app so the
    /// change is visible.
    private func applyVisibility() {
        guard let panel else { return }
        Trace.log("applyVisibility phase=\(model.phase) composing=\(model.isComposingNote) key=\(panel.isKeyWindow)")

        if model.phase == .closed {
            releaseFocus(panel)
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            // `orderFrontRegardless` shows the panel without activating the app,
            // so your editor keeps focus.
            panel.orderFrontRegardless()
        }

        // Buttons and checkboxes work on a click without key status, so the only
        // surface that truly needs the keyboard is the send-back note.
        if model.isComposingNote {
            claimFocus(panel)
        } else {
            releaseFocus(panel)
        }
    }

    /// Lets the shell take the keyboard, and makes that visible.
    private func claimFocus(_ panel: NotchPanel) {
        panel.allowsKey = true
        // Activating is deliberate. Silent key theft, with no change in what looks
        // focused, is the most confusing thing this window can do.
        if !NSApp.isActive {
            NSApp.activate()
        }
        if !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Hands the keyboard back to whatever you were using.
    ///
    /// Never call `resignKey()` for this. That is a notification hook, not a
    /// command: it tells the window it lost key without transferring key status
    /// to anything, which leaves AppKit routing events to a window that believes
    /// it is not focused. Deactivating the app is the real transfer.
    private func releaseFocus(_ panel: NotchPanel) {
        panel.allowsKey = false
        guard panel.isKeyWindow || NSApp.isActive else { return }
        NSApp.deactivate()
    }

    /// Brings the notch forward for a hotkey or a notification action.
    ///
    /// This shows the task. It does not grab the keyboard, because you may only
    /// want to look. Focus follows the note field, through `applyVisibility`.
    func reveal(taskId: String?) {
        if let taskId {
            model.open(taskId: taskId)
        } else if model.pendingCount > 0 {
            model.toggleQueue()
        }
        applyVisibility()
    }
}
