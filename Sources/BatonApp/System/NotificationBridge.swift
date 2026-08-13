import AppKit
import BatonCore
import UserNotifications

/// Notifications and their action buttons.
///
/// Approving from the banner is the fastest path in the product, so the actions
/// carry real weight, not just "View".
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private enum Action {
        static let approve = "BATON_APPROVE"
        static let sendBack = "BATON_SEND_BACK"
        static let snooze = "BATON_SNOOZE"
        static let open = "BATON_OPEN"
    }

    private enum Category {
        static let simple = "BATON_SIMPLE"
        static let checkable = "BATON_CHECKABLE"
        static let digest = "BATON_DIGEST"
    }

    private let model: TaskModel
    private weak var notch: NotchController?
    /// Recent arrivals, so several tasks in a burst become one banner.
    private var coalesceBuffer: [BatonTask] = []
    private var coalesceTimer: Timer?
    private var isAuthorized = false

    init(model: TaskModel, notch: NotchController) {
        self.model = model
        self.notch = notch
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(center)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                Trace.log("authorization granted=\(granted) error=\(error.map(String.init(describing:)) ?? "none")")
                if let error {
                    self?.model.lastError = "Notifications are off: \(error.localizedDescription)"
                }
                self?.logSettings()
            }
        }
    }

    /// Reports what the system actually thinks, which is the only way to tell an
    /// unsigned-bundle problem apart from a Focus or Settings problem.
    private func logSettings() {
        guard Trace.isEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Trace.log(
                "settings authorization=\(settings.authorizationStatus.rawValue) "
                    + "alert=\(settings.alertSetting.rawValue) "
                    + "sound=\(settings.soundSetting.rawValue) "
                    + "style=\(settings.alertStyle.rawValue) "
                    + "notificationCenter=\(settings.notificationCenterSetting.rawValue)"
            )
        }
    }

    private func registerCategories(_ center: UNUserNotificationCenter) {
        let approve = UNNotificationAction(
            identifier: Action.approve,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let sendBack = UNNotificationAction(identifier: Action.sendBack, title: "Send back", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Action.snooze, title: "Snooze 15m", options: [])
        let open = UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.simple,
                actions: [approve, sendBack, snooze],
                intentIdentifiers: [],
                options: []
            ),
            // A task with checks cannot be approved from the banner. Approving
            // without seeing the checks defeats the point of the checklist.
            UNNotificationCategory(
                identifier: Category.checkable,
                actions: [open, snooze],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Category.digest,
                actions: [open],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    // MARK: - Posting

    /// Buffers arrivals for a moment. Three questions from one agent should cost
    /// one banner, not three.
    func taskArrived(_ task: BatonTask) {
        coalesceBuffer.append(task)
        coalesceTimer?.invalidate()
        // Urgent work skips the buffer.
        let delay: TimeInterval = task.priority == .urgent ? 0 : 1.2
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        let batch = coalesceBuffer
        coalesceBuffer = []
        guard !batch.isEmpty else { return }
        if batch.count == 1, let task = batch[0] as BatonTask? {
            post(task: task)
        } else {
            post(digest: batch)
        }
    }

    private func post(task: BatonTask) {
        let content = UNMutableNotificationContent()
        content.title = task.title
        var lines: [String] = []
        if let context = task.contextLabel { lines.append(context) }
        lines.append(task.agent.name)
        content.subtitle = lines.joined(separator: " · ")
        if let body = task.body {
            content.body = String(body.prefix(240))
        } else if let summary = task.changeSummary {
            content.body = summary.headline
        }
        content.categoryIdentifier = task.checklist.isEmpty ? Category.simple : Category.checkable
        content.userInfo = ["taskId": task.id]
        content.interruptionLevel = interruptionLevel(for: task.priority)
        content.sound = task.priority >= .high ? .default : nil
        // Group by worktree so Notification Center stacks them the way you think.
        content.threadIdentifier = task.repo?.worktreePath ?? task.agent.name

        submit(identifier: task.id, content: content)
    }

    private func post(digest batch: [BatonTask]) {
        let content = UNMutableNotificationContent()
        content.title = "\(batch.count) tasks waiting"
        let branches = Set(batch.compactMap { $0.contextLabel })
        content.subtitle = branches.count == 1
            ? (branches.first ?? "")
            : "\(branches.count) worktrees"
        content.body = batch.prefix(3).map(\.title).joined(separator: " · ")
        content.categoryIdentifier = Category.digest
        content.userInfo = ["digest": true]
        content.interruptionLevel = interruptionLevel(for: batch.map(\.priority).max() ?? .normal)
        submit(identifier: "digest-\(UUID().uuidString)", content: content)
    }

    private func interruptionLevel(for priority: BatonTask.Priority) -> UNNotificationInterruptionLevel {
        switch priority {
        case .low: return .passive
        case .normal, .high: return .active
        // Time sensitive breaks through Focus. Reserve it for urgent, and expect
        // the entitlement to be required for a signed build.
        case .urgent: return .timeSensitive
        }
    }

    private func submit(identifier: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Trace.log("post id=\(identifier) error=\(error.map(String.init(describing:)) ?? "none")")
            guard let error else { return }
            Task { @MainActor in
                self?.model.lastError = "Baton cannot post a notification: \(error.localizedDescription)"
            }
        }
    }

    /// Pulls a banner for a task that somebody already resolved, so the queue and
    /// Notification Center never disagree.
    func taskResolved(_ task: BatonTask) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [task.id])
        center.removePendingNotificationRequests(withIdentifiers: [task.id])
    }

    // MARK: - Delegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The notch already shows the task when the app is in front, so a banner
        // would repeat it. Keep the sound and the badge.
        [.sound, .badge, .banner]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let taskId = info["taskId"] as? String else {
            notch?.reveal(taskId: nil)
            return
        }

        switch response.actionIdentifier {
        case Action.approve:
            model.approve(taskId: taskId)
        case Action.snooze:
            model.snooze(taskId: taskId)
        case Action.sendBack:
            model.open(taskId: taskId)
            model.isComposingNote = true
            notch?.reveal(taskId: taskId)
        default:
            notch?.reveal(taskId: taskId)
        }
    }
}
