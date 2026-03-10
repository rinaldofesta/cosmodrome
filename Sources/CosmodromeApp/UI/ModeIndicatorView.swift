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
                Text(modeLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(modeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(modeColor.opacity(0.2))
                            .overlay(
                                Capsule()
                                    .stroke(modeColor.opacity(0.4), lineWidth: 1)
                            )
                    )
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
        }
    }

    private var modeLabel: String {
        switch state.mode {
        case .normal: return "NORMAL"
        case .command: return "CMD"
        }
    }

    private var modeColor: Color {
        switch state.mode {
        case .normal: return .gray
        case .command: return .blue
        }
    }
}
