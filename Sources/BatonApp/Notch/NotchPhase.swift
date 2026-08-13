import BatonCore
import Foundation

/// What the shell shows. The size of every state lives here, so the window and
/// the view never disagree about the interactive area.
enum NotchPhase: Equatable {
    /// No open tasks. The panel is hidden.
    case closed
    /// A pill hugging the notch. Shows the count only.
    case idle
    /// A task just arrived. Auto-collapses to `idle`.
    case peek(String)
    /// The full card for one task.
    case expanded(String)
    /// The task is in progress. A slim bar you can work under.
    case working(String)
    /// Every open task, grouped by worktree.
    case queue
    /// The queue just emptied. A short confirmation beat before the notch goes
    /// away, so finishing the last task reads as completion rather than a glitch.
    case allClear

    var taskId: String? {
        switch self {
        case .peek(let id), .expanded(let id), .working(let id): return id
        case .closed, .idle, .queue, .allClear: return nil
        }
    }

    var isCollapsed: Bool {
        switch self {
        case .closed, .idle, .allClear: return true
        case .peek, .expanded, .working, .queue: return false
        }
    }

    /// True when the phase wants keyboard input, which decides whether the
    /// panel may become key.
    var wantsKeyboard: Bool {
        switch self {
        case .expanded, .queue: return true
        case .closed, .idle, .peek, .working, .allClear: return false
        }
    }

    /// Target width for the shell. Height comes from the measured content,
    /// because a task body has no fixed length.
    func width(metrics: NotchMetrics) -> CGFloat {
        switch self {
        case .closed, .idle: return metrics.idleWidth
        // Wide enough for a checkmark and two words, and still pill-shaped.
        case .allClear: return max(150, metrics.idleWidth)
        case .peek: return max(380, metrics.idleWidth)
        case .working: return max(440, metrics.idleWidth)
        case .expanded, .queue: return NotchMetrics.maximumShellWidth
        }
    }
}
