import BatonCore
import Foundation

/// Debug tracing for the notch. Off unless `BATON_DEBUG=1`.
///
/// The notch is hard to inspect: it has no title bar, it sits above the menu
/// bar, and a breakpoint changes the hover state. A trace log is the practical
/// way to see what it thinks it is doing.
enum Trace {
    static let isEnabled = ProcessInfo.processInfo.environment["BATON_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[baton] \(message())\n".utf8))
    }
}
