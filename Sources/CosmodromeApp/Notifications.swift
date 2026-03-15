import Core
import Foundation
import UserNotifications

/// Request notification permissions and send agent state notifications.
/// Notifications require a proper .app bundle with a bundle identifier.
/// When running as a plain executable (e.g., swift run), these are no-ops.
enum AgentNotifications {
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Track the last time the user interacted with Cosmodrome (mouse click, key press).
    /// Updated from MainWindowController on input events.
    static var lastInteractionTime: Date = Date()

    /// Notification preferences from user config. Defaults to sensible values.
    static var config: UserConfig.NotificationConfig = .default

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func notifyAgentState(project: Project, session: Session) {
        guard isAvailable else { return }

        // Determine the notification type and check if it's enabled
        let agentState = session.agentState
        switch agentState {
        case .needsInput:
            guard config.needsInput else { return }
        case .error:
            guard config.error else { return }
        case .inactive:
            // inactive after working = task completed
            guard config.completed else { return }
        case .working:
            // No notification for working state
            return
        }

        // Smart idle threshold: only notify if user hasn't interacted recently
        let idleDuration = Date().timeIntervalSince(lastInteractionTime)
        guard idleDuration >= Double(config.idleThreshold) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(project.name) — \(session.name)"

        // Rich notification body: use prompt context or narrative for details
        switch agentState {
        case .needsInput:
            if let context = session.promptContext {
                content.body = "Asking: \(String(context.prefix(100)))"
            } else if let narrative = session.narrative, let interp = narrative.interpretation {
                content.body = String(interp.prefix(100))
            } else {
                content.body = "Waiting for input"
            }
        case .error:
            if let narrative = session.narrative, let interp = narrative.interpretation {
                content.body = String(interp.prefix(100))
            } else {
                content.body = "Error encountered"
            }
        case .inactive:
            if let narrative = session.narrative, let interp = narrative.interpretation {
                content.body = String(interp.prefix(100))
            } else {
                content.body = "Task completed"
            }
        case .working:
            return
        }

        content.interruptionLevel = .timeSensitive

        content.userInfo = [
            "projectId": project.id.uuidString,
            "sessionId": session.id.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: session.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func notifyTerminal(project: Project, session: Session, notification: TerminalNotification) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty
            ? "\(project.name) — \(session.name)"
            : notification.title
        content.body = notification.body
        content.interruptionLevel = .active

        content.userInfo = [
            "projectId": project.id.uuidString,
            "sessionId": session.id.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: "osc777-\(session.id.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func clearNotification(for session: Session) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [session.id.uuidString]
        )
    }
}
