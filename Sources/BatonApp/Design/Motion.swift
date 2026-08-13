import BatonCore
import SwiftUI

/// One place for motion and colour, so every surface agrees.
enum Motion {
    /// The shell morph. Slightly bouncy, because the shape change is the whole
    /// point of the notch.
    static let shell = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Content that appears inside a shell that is already the right size.
    static let content = Animation.spring(response: 0.30, dampingFraction: 0.86)
    /// Fast state flips such as a checkbox.
    static let tick = Animation.spring(response: 0.22, dampingFraction: 0.9)

    /// How long a new task stays open before it collapses back to the pill.
    static let peekDuration: TimeInterval = 4.5

    /// Respects the accessibility setting. A reduced-motion user gets a cut, not
    /// a spring.
    static func shell(reduced: Bool) -> Animation {
        reduced ? .linear(duration: 0.01) : shell
    }
}

extension BatonTask.Priority {
    /// The accent that runs through the badge, the ring, and the glass tint.
    var accent: Color {
        switch self {
        case .low: return Color(nsColor: .systemGray)
        case .normal: return Color(nsColor: .systemBlue)
        case .high: return Color(nsColor: .systemOrange)
        case .urgent: return Color(nsColor: .systemPink)
        }
    }

    /// Glass tint stays very light. A strong tint kills legibility on glass.
    var glassTint: Color? {
        switch self {
        case .low, .normal: return nil
        case .high: return accent.opacity(0.10)
        case .urgent: return accent.opacity(0.16)
        }
    }
}

extension BatonTask.Status {
    var label: String {
        switch self {
        case .pending: return "Waiting"
        case .active: return "In progress"
        case .snoozed: return "Snoozed"
        case .done: return "Done"
        case .sentBack: return "Sent back"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A dim label that does not fight the title for attention.
extension Text {
    func metaStyle() -> some View {
        self
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
    }
}
