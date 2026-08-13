import BatonCore
import SwiftUI

/// The root of the notch. One glass shell whose size and content change with the
/// phase. Everything else in the panel is transparent and passes clicks through.
struct NotchRootView: View {
    @Bindable var model: TaskModel
    let metrics: NotchMetrics
    /// Reports the shell frame so the panel can limit its hit area to it.
    var onShellFrame: (CGRect) -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelSpace = "batonPanel"

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(panelSpace))
        .animation(Motion.shell(reduced: reduceMotion), value: model.phase)
    }

    // MARK: - Shell

    private var shell: some View {
        GlassEffectContainer(spacing: 16) {
            content
                .frame(width: model.phase.width(metrics: metrics))
                .frame(height: model.phase.isCollapsed ? metrics.idleHeight : nil)
                .glassEffect(glass, in: shellShape)
                .glassEffectID("shell", in: glassNamespace)
        }
        // Measure after the glass, so the reported rect matches what you see.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(panelSpace))
        } action: { frame in
            Trace.log("shell frame \(frame) phase=\(model.phase)")
            onShellFrame(frame)
        }
        .onHover { inside in
            if inside {
                model.hoverBegan()
            } else {
                model.hoverEnded()
            }
        }
        .opacity(model.phase == .closed ? 0 : 1)
    }

    private var glass: Glass {
        let base = Glass.regular.interactive(!model.phase.isCollapsed)
        guard let tint = model.currentTask?.priority.glassTint ?? model.topPriority?.glassTint else {
            return base
        }
        return base.tint(tint)
    }

    private var shellShape: NotchShape {
        // The shoulders grow with the shell, so the curve stays in proportion.
        model.phase.isCollapsed
            ? NotchShape(shoulder: 8, bottom: metrics.hasHardwareNotch ? 10 : 12)
            : NotchShape(shoulder: 12, bottom: 22)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .closed:
            Color.clear.frame(height: metrics.idleHeight)
        case .idle:
            NotchIdlePill(model: model, metrics: metrics)
        case .peek(let id):
            if let task = model.task(id: id) {
                NotchPeekView(task: task, model: model)
            }
        case .expanded(let id):
            if let task = model.task(id: id) {
                NotchTaskCard(task: task, model: model)
            }
        case .working(let id):
            if let task = model.task(id: id) {
                NotchWorkingBar(task: task, model: model)
            }
        case .queue:
            NotchQueueView(model: model)
        }
    }
}
