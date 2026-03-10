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

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyAgentState(project: Project, session: Session) {
        guard isAvailable else { return }
        guard session.agentState == .needsInput || session.agentState == .error else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(project.name) — \(session.name)"
        content.body = session.agentState == .needsInput
            ? "Waiting for input"
            : "Error encountered"
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

    static func clearNotification(for session: Session) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [session.id.uuidString]
        )
    }
}
