import Foundation

/// Cross-process wake signal.
///
/// The store on disk is the source of truth, so this is only a hint. The app
/// also polls, which means a missed signal delays the notch by one poll
/// interval instead of losing the task.
public enum WakeSignal {
    public static let changedName = "dev.baton.tasksChanged"

    /// Tells any running app that the database changed.
    public static func post() {
        let center = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(changedName as CFString),
            nil,
            nil,
            true
        )
    }

    /// Calls `handler` on the main queue whenever another process posts.
    /// Keep the returned token alive for as long as you want the callbacks.
    public static func observe(_ handler: @escaping () -> Void) -> Token {
        Token(handler: handler)
    }

    public final class Token {
        private var observer: NSObjectProtocol?

        init(handler: @escaping () -> Void) {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(WakeSignal.changedName),
                object: nil,
                queue: .main
            ) { _ in handler() }
        }

        deinit {
            if let observer {
                DistributedNotificationCenter.default().removeObserver(observer)
            }
        }
    }
}
