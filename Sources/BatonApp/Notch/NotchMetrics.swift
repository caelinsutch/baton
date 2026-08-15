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
            // Measure the literal gap between the two areas.
            //
            // Subtracting their widths from the screen width is not the same
            // thing: macOS insets those rects from the display edges, so that
            // arithmetic counts the edge margins as part of the notch and comes out
            // too wide. The pill then sat noticeably wider than the real notch.
            let gap = right.minX - left.maxX
            // Sanity bounds. A notch is roughly 160 to 230 points on current
            // hardware; anything outside that means the rects were not what we
            // assumed, and the synthetic pill is a better answer than a wrong one.
            if gap >= 120, gap <= 400 {
                return NotchMetrics(
                    notchWidth: gap,
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

    /// The screen that should host the notch: the one with the menu bar.
    ///
    /// Preferring whichever display has hardware notch was wrong. With the lid open
    /// beside an external display, the shell appeared on the laptop while you were
    /// working on the other screen. The notch belongs where the menu bar is, which
    /// is the primary display at the origin, and it falls back to a synthetic pill
    /// when that display has no notch.
    static func preferredScreen() -> NSScreen? {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary
        }
        return NSScreen.main ?? NSScreen.screens.first
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
