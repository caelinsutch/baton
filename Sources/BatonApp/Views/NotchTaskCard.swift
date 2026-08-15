import BatonCore
import SwiftUI

/// The full card for one task. It answers three questions: what does the agent
/// want, which worktree is it, and what do I press.
struct NotchTaskCard: View {
    let task: BatonTask
    @Bindable var model: TaskModel

    @FocusState private var noteFocused: Bool
    /// Measured height of the scroll content, so the card fits what it holds.
    @State private var contentHeight: CGFloat = 0

    /// Tallest the body may grow. Past this the content scrolls, so a chatty
    /// agent cannot cover the screen.
    private let maximumBodyHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let body = task.body, !body.isEmpty {
                        Text(markdown(body))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = task.changeSummary {
                        ChangeSummaryRow(summary: summary)
                    }
                    if !task.links.isEmpty {
                        LinkRow(links: task.links, task: task)
                    }
                    if !task.checklist.isEmpty {
                        ChecklistBlock(task: task, model: model)
                    }
                    if !task.choices.isEmpty {
                        ChoiceBlock(task: task, model: model)
                    }
                    if model.isComposingNote {
                        noteField
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                // A ScrollView takes every point it is offered, which left a
                // short task sitting in a tall, mostly empty card. Measure the
                // content and ask for exactly that, up to the cap.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maximumBodyHeight))

            Divider().opacity(0.35)
            actions
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.kind.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(task.priority.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let repo = task.repo {
                        MetaChip(symbol: "arrow.triangle.branch", text: repo.branch ?? repo.folderName)
                        if repo.isDirty == true {
                            MetaChip(symbol: "pencil.line", text: "uncommitted")
                        }
                    }
                    MetaChip(symbol: "cpu", text: task.agent.name)
                    if !task.agent.isAlive {
                        // A dead agent means nobody is waiting. Say so before the
                        // human spends time on it.
                        MetaChip(symbol: "exclamationmark.triangle", text: "agent gone", tint: .orange)
                    }
                    Text(task.createdAt, style: .relative)
                        .metaStyle()
                }
            }

            Spacer(minLength: 4)

            if model.pendingCount > 1 {
                Button {
                    model.setPhase(.queue)
                } label: {
                    Text("\(model.pendingCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .buttonStyle(.glass)
                .help("Show every open task")
            }

            // An explicit way out. Escape works too, but only once the card holds
            // focus, and there was previously no visible control at all.
            Button {
                model.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Close and leave the task open (esc)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 11)
    }

    // MARK: - Note field

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.kind == .input ? "Your answer" : "What should the agent fix?")
                .font(.system(size: 11, weight: .semibold))
            TextEditor(text: Binding(
                get: { model.noteDrafts[task.id] ?? "" },
                set: { model.noteDrafts[task.id] = $0 }
            ))
            .font(.system(size: 12))
            .frame(height: 66)
            .scrollContentBackground(.hidden)
            .padding(6)
            // An opaque well behind text. Glass under a text field hurts reading.
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .focused($noteFocused)
            .onAppear { noteFocused = true }
            Text("Name the file and the line when you can. That is what saves the agent a round trip.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Snooze") { model.snooze(taskId: task.id) }
                .buttonStyle(.glass)
                .help("Hide for 15 minutes. The agent keeps waiting.")

            if !task.checklist.isEmpty, task.status != .active {
                // "Start" said nothing about what happens. This says it: the task
                // shrinks to a bar you can work under in another app.
                Button("Work on it") { model.start(taskId: task.id) }
                    .buttonStyle(.glass)
                    .help("Shrink this to a bar at the top of the screen, so you can "
                        + "check it in another app and tick the checks as you go.")
            }

            Spacer(minLength: 0)

            Button(model.isComposingNote ? "Send back" : "Send back…") {
                if model.isComposingNote {
                    model.sendBack(taskId: task.id)
                } else {
                    model.isComposingNote = true
                }
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Button(confirmLabel) { model.confirm(taskId: task.id) }
                .buttonStyle(.glassProminent)
                .tint(task.priority.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canConfirm)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var confirmLabel: String {
        switch task.kind {
        case .choose: return "Send choice"
        case .input: return "Send answer"
        case .approve: return "Approve"
        // "Done" hides the fact that this approves the work and unblocks the
        // agent. Name the outcome instead.
        default: return "Approve"
        }
    }

    /// A choice task needs a pick. Everything else can confirm at once.
    private var canConfirm: Bool {
        guard task.kind == .choose else { return true }
        return model.choiceDrafts[task.id] != nil
    }

    private func markdown(_ text: String) -> AttributedString {
        // Inline-only, so a long agent note cannot break the layout. Remote
        // images stay out on purpose.
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Blocks

/// A small label with an icon. Used for branch, agent, and warnings.
struct MetaChip: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background((tint ?? .primary).opacity(0.08), in: .capsule)
    }
}

struct ChangeSummaryRow: View {
    let summary: BatonTask.ChangeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(summary.headline)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                if let base = summary.baseRef {
                    Text("vs \(base)").metaStyle()
                }
            }
            // Show a few names, not a diff. The editor is better at diffs.
            Text(summary.files.prefix(5).joined(separator: "  ·  "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            if summary.files.count > 5 {
                Text("and \(summary.files.count - 5) more").metaStyle()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.35), in: .rect(cornerRadius: 9))
    }
}

struct LinkRow: View {
    let links: [BatonTask.Link]
    let task: BatonTask

    var body: some View {
        HStack(spacing: 8) {
            ForEach(links) { link in
                Button {
                    LinkOpener.open(link, task: task)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: LinkOpener.symbol(for: link)).font(.system(size: 10, weight: .semibold))
                        Text(link.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }
                }
                .buttonStyle(.glass)
                .help(link.url)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ChecklistBlock: View {
    let task: BatonTask
    let model: TaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Confirm")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(task.checklist) { item in
                let checked = model.isChecked(taskId: task.id, item: item)
                Button {
                    withAnimation(Motion.tick) {
                        model.toggleChecklistItem(taskId: task.id, itemId: item.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(checked ? Color.accentColor : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(item.text)
                            .font(.system(size: 12))
                            .strikethrough(checked, color: .secondary)
                            .foregroundStyle(checked ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChoiceBlock: View {
    let task: BatonTask
    @Bindable var model: TaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick one")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(Array(task.choices.enumerated()), id: \.element.id) { index, choice in
                let selected = model.choiceDrafts[task.id] == choice.id
                Button {
                    withAnimation(Motion.tick) { model.choiceDrafts[task.id] = choice.id }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.label).font(.system(size: 12, weight: .medium))
                            if let detail = choice.detail {
                                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        // Number the options so the keyboard can pick them.
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
                        in: .rect(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                // Command-modified on purpose. A bare digit would be swallowed
                // by, or would fight with, the send-back note field.
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}
