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
    private var resignObserver: NSObjectProtocol?
    /// Pending window removal, held so an arriving task can cancel it.
    private var hideWork: DispatchWorkItem?
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

        // Clicking another app is the natural way to dismiss an open card.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.resignedActive() }
        }
    }

    func stop() {
        hideWork?.cancel()
        hideWork = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
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
        guard let contentView, let panel else { return }

        // Tracking the frame exactly made the buttons intermittently dead. The
        // frame changes on every animation tick, so a click during the expand
        // spring, or just after the card grew to fit the note field, could land a
        // few points outside a stale rect and fall through to the app underneath.
        // The Approve button sits on the bottom edge, so it was the usual casualty.
        if model.phase.isCollapsed {
            // A small pill leaves most of the strip free, so stay tight and let
            // clicks beside it pass through.
            contentView.interactiveRect = shellFrame.insetBy(dx: -4, dy: -4)
            return
        }

        // An open card fills the panel's width, so there is nothing beside it to
        // pass through to. Claiming the full width and a generous bottom margin
        // removes the race without swallowing clicks meant for other apps.
        contentView.interactiveRect = CGRect(
            x: 0,
            y: 0,
            width: panel.frame.width,
            height: shellFrame.maxY + 12
        )
    }

    // MARK: - Visibility and focus

    private func observePhase() {
        // `withObservationTracking` fires once, so re-arm it after every change.
        withObservationTracking {
            _ = model.phase
            _ = model.pendingCount
            _ = model.isComposingNote
            _ = model.wantsFocus
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
            scheduleHide(panel)
            return
        }
        // Any other phase means the notch is wanted, so drop a pending removal.
        hideWork?.cancel()
        hideWork = nil
        if !panel.isVisible {
            // `orderFrontRegardless` shows the panel without activating the app,
            // so your editor keeps focus.
            panel.orderFrontRegardless()
        }

        // Focus follows a deliberate gesture, not the arrival of a task. Clicking
        // the shell or pressing a shortcut sets `wantsFocus`; a task sliding in
        // never does.
        if model.wantsFocus || model.isComposingNote {
            claimFocus(panel)
        } else {
            releaseFocus(panel)
        }
    }

    /// Removes the window only after the fade finishes.
    ///
    /// Calling `orderOut` the moment the phase changes cut the collapse animation
    /// halfway, which is what made finishing the last task look broken. SwiftUI
    /// needs the window to stay on screen for the length of the transition.
    private func scheduleHide(_ panel: NotchPanel) {
        releaseFocus(panel)
        guard panel.isVisible else { return }
        guard hideWork == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            // Re-check: a task may have arrived while the shell was fading.
            guard self.model.phase == .closed else { return }
            panel.orderOut(nil)
        }
        hideWork = work
        // Slightly longer than the shell spring, so the fade completes off-camera
        // rather than being clipped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
            model.openWithFocus(taskId: taskId)
        } else {
            model.toggleOpen()
        }
        applyVisibility()
    }

    /// Opens the notch, or closes it if it is already open.
    func toggleOpen() {
        model.toggleOpen()
        applyVisibility()
    }
}
