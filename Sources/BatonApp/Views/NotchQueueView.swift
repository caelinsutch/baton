import BatonCore
import SwiftUI

/// Every open task, grouped by worktree.
///
/// Grouping by branch is the point of the whole app. With ten agents running you
/// think in worktrees, not in tasks.
struct NotchQueueView: View {
    @Bindable var model: TaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groupedByWorktree, id: \.label) { group in
                        WorktreeGroup(group: group, model: model)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 380)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Waiting on you")
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(model.pendingCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: .capsule)
            Spacer(minLength: 0)
            Text("↩ open   ⌘↩ approve   esc close")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

struct WorktreeGroup: View {
    let group: (label: String, tasks: [BatonTask])
    @Bindable var model: TaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(group.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if group.tasks.count > 1 {
                    // Draining a whole worktree in one press matters when an
                    // agent asks three small questions in a row.
                    Button("Approve all") {
                        for task in group.tasks where task.kind != .choose && task.kind != .input {
                            model.approve(taskId: task.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
                }
            }
            ForEach(group.tasks) { task in
                QueueRow(task: task, model: model)
            }
        }
    }
}

struct QueueRow: View {
    let task: BatonTask
    @Bindable var model: TaskModel

    @State private var isHovering = false

    var body: some View {
        Button {
            model.open(taskId: task.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: task.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(task.priority.accent)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text(task.agent.name).metaStyle()
                        Text("·").metaStyle()
                        Text(task.createdAt, style: .relative).metaStyle()
                        if task.status == .active {
                            Text("· in progress").metaStyle().foregroundStyle(task.priority.accent)
                        }
                    }
                }

                Spacer(minLength: 4)

                if isHovering {
                    // Actions appear on hover, so the resting list stays quiet.
                    HStack(spacing: 5) {
                        Button {
                            model.snooze(taskId: task.id)
                        } label: {
                            Image(systemName: "clock").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Snooze 15 minutes")

                        Button {
                            model.approve(taskId: task.id)
                        } label: {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Approve")
                        .disabled(task.kind == .choose || task.kind == .input)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isHovering ? Color.primary.opacity(0.06) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.tick) { isHovering = hovering }
        }
    }
}
