import Core
import SwiftUI

/// Slide-out panel showing per-project activity timeline.
/// Toggled with Cmd+L.
struct ActivityLogView: View {
    let activityLog: ActivityLog
    let projectName: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Activity Log")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)))

            Divider()
                .background(Color.white.opacity(0.1))

            // Event list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let events = activityLog.events.suffix(500)
                        ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                            ActivityEventRow(event: event)
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)))
    }
}

private struct ActivityEventRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 40, alignment: .trailing)

            // Icon
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundColor(iconColor)
                .frame(width: 14)

            // Session name
            Text(event.sessionName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)

            // Description
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: event.timestamp)
    }

    private var iconName: String {
        switch event.kind {
        case .taskStarted: return "play.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .fileRead: return "doc"
        case .fileWrite: return "doc.fill"
        case .commandRun: return "terminal"
        case .error: return "exclamationmark.triangle.fill"
        case .modelChanged: return "cpu"
        case .stateChanged: return "arrow.right"
        case .subagentStarted: return "arrow.triangle.branch"
        case .subagentCompleted: return "checkmark.diamond"
        case .commandCompleted: return "terminal.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .taskStarted: return .green
        case .taskCompleted: return .green
        case .fileRead: return .blue
        case .fileWrite: return .orange
        case .commandRun: return .cyan
        case .error: return .red
        case .modelChanged: return .purple
        case .stateChanged: return .gray
        case .subagentStarted: return .teal
        case .subagentCompleted: return .teal
        case .commandCompleted: return .mint
        }
    }

    private var description: String {
        switch event.kind {
        case .taskStarted:
            return "Started working"
        case .taskCompleted(let duration):
            return "Task completed (\(formatDuration(duration)))"
        case .fileRead(let path):
            return "Read \(path)"
        case .fileWrite(let path, let added, let removed):
            var s = "Write \(path)"
            if let a = added, let r = removed {
                s += " (+\(a) -\(r))"
            }
            return s
        case .commandRun(let command):
            return "Bash: \(command)"
        case .error(let message):
            return message
        case .modelChanged(let model):
            return "Model: \(model)"
        case .stateChanged(let from, let to):
            return "\(from.rawValue) → \(to.rawValue)"
        case .subagentStarted(let name, let description):
            return "Subagent: \(name) — \(description)"
        case .subagentCompleted(let name, let duration):
            return "Subagent done: \(name) (\(formatDuration(duration)))"
        case .commandCompleted(let command, let exitCode, let duration):
            let cmd = command ?? "command"
            let code = exitCode.map { " [exit \($0)]" } ?? ""
            return "\(cmd)\(code) (\(formatDuration(duration)))"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
