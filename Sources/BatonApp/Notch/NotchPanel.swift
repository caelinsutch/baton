import AppKit

/// The panel that hosts the notch shell.
///
/// It must sit above the menu bar, never take focus by itself, follow you across
/// spaces, and pass clicks through everywhere the shell does not draw.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            // `.nonactivatingPanel` is the important one. Without it, showing the
            // notch would pull focus out of your editor.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Draw over the menu bar. `.statusBar` alone sits level with it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        hidesOnDeactivate = false
        // Key status is opt-in. See `allowsKey`.
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isRestorable = false
        // Hover drives the whole expand gesture, and a borderless panel does not
        // get mouse-moved events by default.
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // Leave `sharingType` at its default. Excluding the panel from capture
        // would also hide it from screenshots and screen sharing, and sending a
        // screenshot of a task is a normal thing to want.
    }

    /// Whether the panel may take the keyboard right now.
    ///
    /// Default off. A nonactivating panel that becomes key steals keystrokes from
    /// the app you are typing in while that app still looks focused, which is the
    /// most confusing thing this window can do. `NotchController` turns this on
    /// only for a text surface, and activates the app at the same time so the
    /// focus change is visible.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Escape closes the shell instead of beeping.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    var onCancel: (() -> Void)?
}

/// Passes mouse events through everywhere the shell does not draw.
///
/// A borderless panel normally swallows clicks across its whole frame. The frame
/// here is much larger than the visible shell, so without this the notch would
/// block a wide strip at the top of the screen.
final class PassthroughView: NSView {
    /// The area the shell currently occupies, in this view's coordinates.
    var interactiveRect: CGRect = .zero

    /// Flipped on purpose.
    ///
    /// SwiftUI measures from the top left, and `interactiveRect` comes straight
    /// from a SwiftUI geometry reading. An unflipped view would put the hit area
    /// at the bottom of the panel, hundreds of points below the visible shell,
    /// and every click would fall through to the app underneath.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else {
            Trace.log("hitTest miss local=\(local) rect=\(interactiveRect)")
            return nil
        }
        return super.hitTest(point)
    }

    /// Keeps AppKit from treating the empty area as a draggable background.
    override var mouseDownCanMoveWindow: Bool { false }
}
