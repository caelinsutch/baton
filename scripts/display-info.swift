#!/usr/bin/env swift
//
// Prints what Baton sees on every display, and what it would compute from that.
//
// Run this on a MacBook to check the hardware notch path. It needs no build and no
// running app, so it is the quickest way to tell a geometry bug from a layout bug.
//
// Usage:
//   swift scripts/display-info.swift

import AppKit

/// Mirrors `NotchMetrics.measure`, so the numbers here are the numbers the app
/// uses. Keep the two in step.
func describe(_ screen: NSScreen, index: Int) {
    let frame = screen.frame
    let inset = screen.safeAreaInsets.top
    let left = screen.auxiliaryTopLeftArea
    let right = screen.auxiliaryTopRightArea

    print("Display \(index)\(screen == NSScreen.main ? "  (main)" : "")")
    print("  localizedName        \(screen.localizedName)")
    print("  frame                \(format(frame))")
    print("  visibleFrame         \(format(screen.visibleFrame))")
    print("  backingScaleFactor   \(screen.backingScaleFactor)")
    print("  safeAreaInsets.top   \(inset)")
    print("  auxiliaryTopLeft     \(left.map(format) ?? "nil")")
    print("  auxiliaryTopRight    \(right.map(format) ?? "nil")")

    guard inset > 0, let left, let right else {
        let menuBar = frame.height
            - (screen.visibleFrame.height + screen.visibleFrame.origin.y - frame.origin.y)
        print("  -> no hardware notch")
        print("     menu bar height   \(menuBar)")
        print("     pill              190 x \(max(menuBar, 24)) (synthetic)")
        print("")
        return
    }

    // The gap between the two areas. Subtracting their widths from the screen
    // width counts the display edge margins as notch, which came out too wide.
    let gap = right.minX - left.maxX
    let subtraction = frame.width - left.width - right.width

    print("  -> hardware notch")
    print("     gap  (correct)    \(gap)")
    print("     subtraction (old) \(subtraction)   difference \(subtraction - gap)")
    if gap < 120 || gap > 400 {
        print("     WARNING: outside 120...400, so the app falls back to a synthetic pill")
    }
    print("     pill              \(gap + 16) x \(inset)")
    let panelWidth = max(620, gap + 80)
    print("     panel             \(panelWidth) x 560 at x \(frame.midX - panelWidth / 2), y \(frame.maxY - 560)")
    print("")
}

func format(_ rect: CGRect) -> String {
    "(\(Int(rect.origin.x)), \(Int(rect.origin.y)), \(Int(rect.width)) x \(Int(rect.height)))"
}

print("")
for (index, screen) in NSScreen.screens.enumerated() {
    describe(screen, index: index)
}

let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
print("Baton would host the notch on: \(notched?.localizedName ?? NSScreen.main?.localizedName ?? "unknown")")
print("")
