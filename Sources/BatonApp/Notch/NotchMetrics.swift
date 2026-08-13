import AppKit

/// Measures the hardware notch so the shell can hug it.
struct NotchMetrics: Equatable {
    /// Width of the physical notch, in points.
    var notchWidth: CGFloat
    /// Height of the notch, which equals the top safe area inset.
    var notchHeight: CGFloat
    /// Full screen frame, in Cocoa coordinates.
    var screenFrame: CGRect
    /// True on a display with a real notch.
    var hasHardwareNotch: Bool

    /// The shell never gets narrower than this, so the count badge always fits.
    static let minimumShellWidth: CGFloat = 190
    /// Widest state the window has to hold.
    static let maximumShellWidth: CGFloat = 620
    /// Tallest state the window has to hold.
    static let maximumShellHeight: CGFloat = 560

    static func measure(screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        let inset = screen.safeAreaInsets.top

        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas sit either side of the notch, so the gap
            // between them is the notch itself.
            let width = max(frame.width - left.width - right.width, 0)
            if width > 0 {
                return NotchMetrics(
                    notchWidth: width,
                    notchHeight: inset,
                    screenFrame: frame,
                    hasHardwareNotch: true
                )
            }
        }

        // No notch. Use the menu bar height and a synthetic pill width, so the
        // same design works on an external display.
        let menuBarHeight = frame.height - (screen.visibleFrame.height + screen.visibleFrame.origin.y - frame.origin.y)
        return NotchMetrics(
            notchWidth: minimumShellWidth,
            notchHeight: max(menuBarHeight, 24),
            screenFrame: frame,
            hasHardwareNotch: false
        )
    }

    /// The screen that should host the notch. Prefers the display with real
    /// hardware notch, then the one holding the mouse.
    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Frame for the host panel. It stays fixed and generous, so the shell
    /// animates inside it and the window frame never animates.
    var panelFrame: CGRect {
        let width = max(Self.maximumShellWidth, notchWidth + 80)
        let height = Self.maximumShellHeight
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Width of the idle pill. It overlaps the notch edges slightly, so the two
    /// read as one object.
    var idleWidth: CGFloat {
        hasHardwareNotch ? notchWidth + 16 : Self.minimumShellWidth
    }

    var idleHeight: CGFloat { notchHeight }
}
