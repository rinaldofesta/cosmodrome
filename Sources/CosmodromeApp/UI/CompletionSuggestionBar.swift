import Core
import SwiftUI

/// Transient bar shown at the bottom of a terminal session when an agent
/// completes a task. Auto-dismisses after 30 seconds. Never blocks input.
struct CompletionSuggestionBar: View {
    let actions: [CompletionActions.Action]
    let duration: TimeInterval
    let filesCount: Int
    var onAction: (String) -> Void
    var onDismiss: () -> Void

    @State private var visible = true

    var body: some View {
        if visible {
            HStack(spacing: 12) {
                // Summary
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)

                    Text(summaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                // Action buttons
                ForEach(actions, id: \.id) { action in
                    Button(action: { onAction(action.id) }) {
                        HStack(spacing: 3) {
                            Image(systemName: action.icon)
                                .font(.system(size: 10))
                            Text(action.label)
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Dismiss
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) { visible = false }
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // Auto-dismiss after 30 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    withAnimation(.easeOut(duration: 0.3)) { visible = false }
                    onDismiss()
                }
            }
        }
    }

    private var summaryText: String {
        let durationStr = formatDuration(duration)
        if filesCount > 0 {
            return "Task completed (\(durationStr), \(filesCount) files)"
        }
        return "Task completed (\(durationStr))"
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
