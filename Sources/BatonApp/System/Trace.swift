import BatonCore
import Foundation

/// Debug tracing for the notch and for notifications.
///
/// The notch is hard to inspect: it has no title bar, it sits above the menu bar,
/// and a breakpoint changes the hover state. A trace log is the practical way to
/// see what it thinks it is doing.
///
/// Tracing turns on in either of two ways, because the app has to be launched
/// two different ways:
///   - `BATON_DEBUG=1` when you exec the binary from a shell
///   - a `DEBUG` marker file, for when LaunchServices starts the app and there is
///     no way to pass an environment variable
///
/// Notification authorization depends on being launched by LaunchServices, so
/// diagnosing it means using `open`, which is exactly the case the env var cannot
/// cover.
enum Trace {
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["BATON_DEBUG"] == "1" { return true }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }()

    /// Touch this file to trace an `open`-launched run.
    static var markerURL: URL {
        BatonPaths.supportDirectory.appendingPathComponent("DEBUG")
    }

    /// Opens the full card on arrival instead of peeking.
    ///
    /// Separate from tracing on purpose. Working on the card wants this on, and
    /// testing the pill needs it off while still reading the log.
    static let autoExpand: Bool = {
        if ProcessInfo.processInfo.environment["BATON_DEBUG_EXPAND"] == "1" { return true }
        return FileManager.default.fileExists(atPath: expandMarkerURL.path)
    }()

    static var expandMarkerURL: URL {
        BatonPaths.supportDirectory.appendingPathComponent("DEBUG_EXPAND")
    }

    static var logURL: URL {
        BatonPaths.supportDirectory.appendingPathComponent("app.log")
    }

    private static let lock = NSLock()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(stamp())] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))

        // Also to a file, so a LaunchServices run is observable.
        lock.lock()
        defer { lock.unlock() }
        BatonPaths.ensureSupportDirectory()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
