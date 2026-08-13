import AppKit
import BatonCore
import SwiftUI

/// The app's long-lived objects.
///
/// They live here rather than on the delegate because SwiftUI reads them while it
/// builds the menu bar item. A delegate property is optional until launch
/// finishes and is not observable, so the menu bar label would never update.
@MainActor
final class BatonServices {
    static let shared = BatonServices()

    let model: TaskModel
    let notch: NotchController
    let notifications: NotificationBridge

    private var didStart = false

    private init() {
        let model = TaskModel()
        let notch = NotchController(model: model)
        self.model = model
        self.notch = notch
        self.notifications = NotificationBridge(model: model, notch: notch)
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        model.onNewTask = { [notifications] task in
            notifications.taskArrived(task)
        }
        model.onTaskResolved = { [notifications] task in
            notifications.taskResolved(task)
        }

        notch.start()
        notifications.start()
        model.start()
        installHotKeys()
    }

    func stop() {
        model.stop()
        notch.stop()
    }

    private func installHotKeys() {
        HotKeyCenter.shared.install(
            toggleQueue: { [model, notch] in
                model.toggleQueue()
                notch.reveal(taskId: model.phase.taskId)
            },
            markDone: { [model] in
                // Acts on whatever the notch shows, so the shortcut works from
                // inside another app.
                guard let id = model.phase.taskId ?? model.visibleTasks.first?.id else { return }
                model.confirm(taskId: id)
            },
            sendBack: { [model, notch] in
                guard let id = model.phase.taskId ?? model.visibleTasks.first?.id else { return }
                model.open(taskId: id)
                model.isComposingNote = true
                notch.reveal(taskId: id)
            }
        )
    }
}

@main
struct BatonAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: BatonServices.shared.model, notch: BatonServices.shared.notch)
        } label: {
            MenuBarLabel(model: BatonServices.shared.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph. Shows a count only when tasks wait.
struct MenuBarLabel: View {
    var model: TaskModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if model.pendingCount > 0 {
                Text("\(model.pendingCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }

    private var symbolName: String {
        guard model.pendingCount > 0 else { return "circle.dashed" }
        return model.topPriority == .urgent ? "exclamationmark.circle.fill" : "circle.fill"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app with no Dock icon. The notch is the main surface.
        NSApp.setActivationPolicy(.accessory)
        BatonServices.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BatonServices.shared.stop()
    }

    /// Keep running with no windows. The menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
