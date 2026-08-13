// Mouse input for the demo recording.
//
// Compiled on demand by scripts/record-demo.sh. It lives here rather than in a
// temporary directory so the recording is reproducible.
//
// Needs Accessibility permission for whichever terminal runs it, because posting
// a synthetic click is exactly what that permission gates.
//
// Usage:
//   demo-input warp  <x> <y>   Move the cursor
//   demo-input click <x> <y>   Move, then click

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("demo-input: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3,
      let pointX = Double(arguments[1]),
      let pointY = Double(arguments[2]) else {
    fail("usage: demo-input <warp|click> <x> <y>")
}

let point = CGPoint(x: pointX, y: pointY)
CGWarpMouseCursorPosition(point)
// Reassociate, or the cursor keeps drifting from real mouse input.
CGAssociateMouseAndMouseCursorPosition(1)

switch arguments[0] {
case "warp":
    break
case "click":
    // A short settle before pressing, so hover states have a chance to draw and
    // the recording shows the button reacting rather than jumping.
    usleep(180_000)
    for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            fail("could not create a mouse event")
        }
        event.post(tap: .cghidEventTap)
        usleep(70_000)
    }
default:
    fail("unknown command '\(arguments[0])'")
}
