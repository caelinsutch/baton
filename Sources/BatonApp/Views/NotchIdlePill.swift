import BatonCore
import SwiftUI

/// The resting state. It hugs the notch and shows only a count, because at rest
/// the notch must not compete with your work.
struct NotchIdlePill: View {
    let model: TaskModel
    let metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 6) {
            if metrics.hasHardwareNotch {
                // The hardware notch already fills the middle. Push the badge to
                // the right shoulder so nothing hides behind the camera.
                Spacer(minLength: 0)
            }
            PriorityDot(priority: model.topPriority ?? .normal, pulses: model.topPriority == .urgent)
            Text("\(model.pendingCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if !metrics.hasHardwareNotch {
                Text(model.pendingCount == 1 ? "task" : "tasks")
                    .metaStyle()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: metrics.idleHeight)
        .contentTransition(.numericText())
        // Clickable as well as hoverable. A click is what people try first.
        .contentShape(.rect)
        .onTapGesture { model.openFromShell() }
    }
}

/// A small dot that carries the priority colour. The urgent case breathes, which
/// is the only motion in the resting state.
struct PriorityDot: View {
    let priority: BatonTask.Priority
    var pulses: Bool = false

    @State private var isBig = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(priority.accent)
            .frame(width: 7, height: 7)
            .scaleEffect(isBig ? 1.35 : 1)
            .shadow(color: priority.accent.opacity(0.6), radius: isBig ? 4 : 0)
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isBig = true
                }
            }
    }
}

/// The arrival state. Enough to decide whether to stop what you are doing.
struct NotchPeekView: View {
    let task: BatonTask
    let model: TaskModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.kind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(task.priority.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let context = task.contextLabel {
                    Text(context)
                        .metaStyle()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Text("\(model.pendingCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .transition(.opacity.combined(with: .offset(y: -4)))
        .contentShape(.rect)
        .onTapGesture { model.openFromShell() }
    }
}

/// The goodbye. Shown for about a second after the queue empties.
///
/// Without it, resolving the last task collapsed a wide card into nothing while
/// the window was being removed, which read as a glitch rather than as finishing.
struct NotchAllClearPill: View {
    let metrics: NotchMetrics

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating.speed(4) : .nonRepeating, value: hasAppeared)
            Text("All clear")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: metrics.idleHeight)
        .onAppear { hasAppeared = true }
    }
}
