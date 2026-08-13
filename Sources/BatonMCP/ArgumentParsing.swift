import BatonCore
import Foundation

/// Turns loose tool arguments into model values. Agents send strings where the
/// schema asks for objects, so accept both shapes instead of failing.
enum ArgumentParsing {
    static func links(_ value: JSONValue?) -> [BatonTask.Link] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.compactMap { entry in
            if let url = entry.stringValue {
                return BatonTask.Link(label: shortLabel(for: url), url: url)
            }
            guard let url = entry["url"]?.stringValue else { return nil }
            let target = BatonTask.Link.Target(rawValue: entry["openIn"]?.stringValue ?? "") ?? .browser
            return BatonTask.Link(
                label: entry["label"]?.stringValue ?? shortLabel(for: url),
                url: url,
                openIn: target
            )
        }
    }

    static func choices(_ value: JSONValue?) -> [BatonTask.Choice] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.compactMap { entry in
            if let label = entry.stringValue {
                return BatonTask.Choice(label: label)
            }
            guard let label = entry["label"]?.stringValue else { return nil }
            return BatonTask.Choice(label: label, detail: entry["detail"]?.stringValue)
        }
    }

    static func checklist(_ value: JSONValue?) -> [BatonTask.ChecklistItem] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.compactMap { entry in
            if let text = entry.stringValue {
                return BatonTask.ChecklistItem(text: text)
            }
            guard let text = entry["text"]?.stringValue else { return nil }
            return BatonTask.ChecklistItem(text: text, required: entry["required"]?.boolValue ?? true)
        }
    }

    /// Picks a kind when the agent omits it, so the card still looks right.
    static func inferKind(hasChoices: Bool, hasSummary: Bool, hasLinks: Bool) -> BatonTask.Kind {
        if hasChoices { return .choose }
        if hasSummary { return .reviewChange }
        if hasLinks { return .verify }
        return .approve
    }

    private static func shortLabel(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "Open link" }
        if let host = url.host, !host.isEmpty {
            return url.path.count > 1 ? "\(host)\(url.path)" : host
        }
        return url.lastPathComponent.isEmpty ? "Open link" : url.lastPathComponent
    }
}

/// Starts the app when it is not running.
///
/// A submit works without the app because the store is on disk. The app still
/// has to run to show the notch and to post the notification, so nudge it.
enum AppLauncher {
    private static var lastNudge = Date.distantPast
    private static let lock = NSLock()

    static func nudge() {
        guard ProcessInfo.processInfo.environment["BATON_NO_LAUNCH"] != "1" else { return }
        lock.lock()
        let shouldRun = Date().timeIntervalSince(lastNudge) > 10
        if shouldRun { lastNudge = Date() }
        lock.unlock()
        guard shouldRun, !isAppRunning() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-g` keeps the current app in front. The notch appears without stealing focus.
        process.arguments = ["-g", "-b", BatonPaths.bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func isAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "BatonApp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
