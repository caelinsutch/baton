import BatonCore
import SwiftUI

/// The state you work under.
///
/// You pinned the task and moved to Chrome or Xcode. This bar stays at the top of
/// the screen, shows the one thing to check next, and lets you finish without
/// hunting for the app. It never takes focus, so typing keeps going to the other
/// app.
///
/// Three controls, three jobs, and each one says which:
///   - the checkbox ticks the check you are looking at
///   - "Send back" returns the task to the agent with a note
///   - "Approve" resolves the task and unblocks the agent
struct NotchWorkingBar: View {
    let task: BatonTask
    @Bindable var model: TaskModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressRing(done: doneCount, total: task.checklist.count, accent: task.priority.accent)

            checkRow

            Spacer(minLength: 8)

            Button {
                model.sendBack(taskId: task.id)
            } label: {
                Label("Send back", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.glass)
            .help("Return the task to the agent with a note (⌥⌘⌫)")

            Button {
                model.confirm(taskId: task.id)
            } label: {
                Text(confirmLabel)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(task.priority.accent)
            .help(confirmHelp)

            Button {
                model.open(taskId: task.id)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Show the whole task")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .transition(.opacity)
    }

    // MARK: - The check in front of you

    /// One check at a time, as a real checkbox with its text.
    ///
    /// An unlabelled checkmark button reads as "finish", which is the wrong
    /// action. The box and the sentence together read as "tick this one".
    @ViewBuilder
    private var checkRow: some View {
        if let item = nextItem {
            Button {
                withAnimation(Motion.tick) {
                    model.toggleChecklistItem(taskId: task.id, itemId: item.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.text)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(remainingLabel)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Tick this check")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(task.checklist.isEmpty ? task.title : "All checks passed")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let context = task.contextLabel {
                    Text(context)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Labels

    /// Says what the button sends, so "Done" never hides an approval.
    private var confirmLabel: String {
        switch task.kind {
        case .choose: return "Send choice"
        case .input: return "Send answer"
        default: return "Approve"
        }
    }

    private var confirmHelp: String {
        let action = "Resolves the task and unblocks the agent (⌥⌘↩)."
        guard remaining > 0 else { return action }
        return "\(action) \(remaining) check\(remaining == 1 ? "" : "s") still unticked, "
            + "and the agent is told which ones."
    }

    private var remainingLabel: String {
        let context = task.contextLabel.map { "\($0) · " } ?? ""
        return "\(context)\(doneCount) of \(task.checklist.count) checked"
    }

    // MARK: - Progress

    private var doneCount: Int {
        task.checklist.filter { model.isChecked(taskId: task.id, item: $0) }.count
    }

    private var remaining: Int {
        task.checklist.count - doneCount
    }

    /// The first unticked item. Showing one at a time keeps the bar short.
    private var nextItem: BatonTask.ChecklistItem? {
        task.checklist.first { !model.isChecked(taskId: task.id, item: $0) }
    }
}

/// Progress as a ring. It reads from the corner of your eye, which a text counter
/// does not.
struct ProgressRing: View {
    let done: Int
    let total: Int
    let accent: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if total == 0 {
                Circle().fill(accent).frame(width: 6, height: 6)
            } else if done == total {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 20, height: 20)
        .animation(Motion.tick, value: fraction)
    }
}
