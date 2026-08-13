import Foundation

/// Every path the app and the CLI share.
public enum BatonPaths {
    public static let bundleIdentifier = "dev.baton.Baton"

    /// `~/Library/Application Support/dev.baton`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("dev.baton", isDirectory: true)
    }

    public static var databaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["BATON_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return supportDirectory.appendingPathComponent("tasks.db")
    }

    public static var logURL: URL {
        supportDirectory.appendingPathComponent("baton-mcp.log")
    }

    @discardableResult
    public static func ensureSupportDirectory() -> Bool {
        let dir = databaseURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
