import Observation
import SwiftUI

@Observable
final class ModeIndicatorState {
    var mode: KeybindingManager.Mode = .normal
    var isVisible = false
}

/// Small pill overlay showing the current keybinding mode.
/// Appears in the bottom-right corner of the terminal area.
struct ModeIndicatorView: View {
    @Bindable var state: ModeIndicatorState

    var body: some View {
        if state.isVisible {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    // Mode label
                    Text(modeLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(modeColor)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs + 1)
                        .background(
                            Capsule()
                                .fill(modeColor.opacity(0.15))
                                .overlay(
                                    Capsule()
                                        .stroke(modeColor.opacity(0.35), lineWidth: 1)
                                )
                        )
                        .shadow(color: modeColor.opacity(0.2), radius: 6)

                    // Key hints (only in command mode)
                    if state.mode == .command {
                        HStack(spacing: Spacing.sm) {
                            keyHint("j/k", label: "session")
                            keyHint("h/l", label: "project")
                            keyHint("f", label: "focus")
                            keyHint("p", label: "palette")
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.trailing, Spacing.md)
                .padding(.bottom, Spacing.sm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(Anim.normal, value: state.isVisible)
            .animation(Anim.normal, value: state.mode)
        }
    }

    @ViewBuilder
    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.textSecondary)
            Text(label)
                .font(Typo.caption)
                .foregroundColor(DS.textTertiary)
        }
    }

    private var modeLabel: String {
        switch state.mode {
        case .normal: return "NORMAL"
        case .command: return "COMMAND"
        }
    }

    private var modeColor: Color {
        switch state.mode {
        case .normal: return DS.textTertiary
        case .command: return DS.accent
        }
    }
}
