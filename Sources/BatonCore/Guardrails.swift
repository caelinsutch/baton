import Foundation

/// Rules that protect the human from a misbehaving agent.
public enum Guardrails {
    /// Tasks one session may create per minute.
    public static let submitsPerMinute = 20
    public static let maxTitleLength = 120
    public static let maxBodyLength = 8000
    public static let maxLinks = 8
    public static let maxChoices = 8
    public static let maxChecklistItems = 20
    public static let maxBlockingWait: TimeInterval = 900
    public static let defaultBlockingWait: TimeInterval = 120

    /// Link schemes the app is willing to open. Anything else is text only.
    /// `javascript:` and unknown custom schemes stay out on purpose.
    public static let allowedSchemes: Set<String> = [
        "http", "https", "file", "vscode", "vscode-insiders", "cursor",
        "zed", "windsurf", "x-github-client", "github-mac", "xcode",
    ]

    public static func isAllowed(urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Cuts a string to a limit and marks the cut.
    public static func clamp(_ value: String, to limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Applies every limit to a task before it reaches the store.
    public static func sanitize(_ task: BatonTask) -> BatonTask {
        var clean = task
        // Trim before the empty check. A whitespace-only title is empty in
        // practice, and an empty card tells the human nothing.
        let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.title = clamp(trimmedTitle.isEmpty ? "Untitled task" : trimmedTitle, to: maxTitleLength)
        clean.body = task.body.map { clamp($0, to: maxBodyLength) }
        clean.links = Array(task.links.filter { isAllowed(urlString: $0.url) }.prefix(maxLinks))
        clean.choices = Array(task.choices.prefix(maxChoices))
        clean.checklist = Array(task.checklist.prefix(maxChecklistItems))
        if let summary = clean.changeSummary {
            var bounded = summary
            bounded.files = Array(summary.files.prefix(40))
            clean.changeSummary = bounded
        }
        return clean
    }

    public enum Violation: Swift.Error, CustomStringConvertible {
        case rateLimited(Int)
        case emptyTitle

        public var description: String {
            switch self {
            case .rateLimited(let count):
                return "Rate limit reached. This session created \(count) tasks in the last minute. "
                    + "Batch the questions into one task, or wait."
            case .emptyTitle:
                return "The task needs a title."
            }
        }
    }

    /// Throws when the session already submitted too many tasks.
    public static func checkRate(store: TaskStore, sessionId: String?) throws {
        let since = Date().addingTimeInterval(-60)
        let count = (try? store.recentCount(sessionId: sessionId, since: since)) ?? 0
        if count >= submitsPerMinute {
            throw Violation.rateLimited(count)
        }
    }
}
