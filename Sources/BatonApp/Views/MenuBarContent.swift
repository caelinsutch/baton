import BatonCore
import SwiftUI

/// The menu bar item. Always reachable, even when the notch is hidden.
struct MenuBarContent: View {
    @Bindable var model: TaskModel
    var notch: NotchController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }

            if model.visibleTasks.isEmpty {
                emptyState
            } else {
                queue
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing waiting")
                .font(.system(size: 12, weight: .semibold))
            Text("Agents can reach you through the baton MCP tool.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.visibleTasks) { task in
                Button {
                    notch?.reveal(taskId: task.id)
                } label: {
                    HStack(spacing: 8) {
                        PriorityDot(priority: task.priority)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(task.title).font(.system(size: 12)).lineLimit(1)
                            if let context = task.contextLabel {
                                Text(context).metaStyle().lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Show queue", shortcut: "⌥⌘B") {
                notch?.reveal(taskId: nil)
            }
            MenuRow(title: "Recently resolved", shortcut: nil, isEnabled: !model.recentlyResolved.isEmpty) {
                // Resolved tasks are read-only history, so the queue view is the
                // right surface for them once it grows a history tab.
                notch?.reveal(taskId: nil)
            }
            Divider().padding(.vertical, 4)
            MenuRow(title: "Quit Baton", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MenuRow: View {
    let title: String
    let shortcut: String?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isHovering ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }
}
