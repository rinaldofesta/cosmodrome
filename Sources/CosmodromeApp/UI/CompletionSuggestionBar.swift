import Core
import SwiftUI

/// Transient bar shown at the bottom of a terminal session when an agent
/// completes a task. Auto-dismisses after 30 seconds. Never blocks input.
struct CompletionSuggestionBar: View {
    let actions: [CompletionActions.Action]
    let summaryText: String
    var onAction: (String) -> Void
    var onDismiss: () -> Void

    @State private var visible = true

    var body: some View {
        if visible {
            HStack(spacing: Spacing.md) {
                // Summary
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Typo.body)
                        .foregroundColor(DS.stateWorking)

                    Text(summaryText)
                        .font(Typo.bodyMedium)
                        .foregroundColor(DS.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                // Action buttons
                ForEach(actions, id: \.id) { action in
                    Button(action: { onAction(action.id) }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: action.icon)
                                .font(Typo.footnote)
                            Text(action.label)
                                .font(Typo.body)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(DS.bgHover)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .stroke(DS.borderMedium, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.textPrimary)
                }

                // Dismiss
                Button(action: {
                    withAnimation(Anim.normal) { visible = false }
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .stroke(DS.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: DS.shadowLight, radius: 8, y: 2)
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // Auto-dismiss after 30 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    withAnimation(Anim.slow) { visible = false }
                    onDismiss()
                }
            }
        }
    }
}
