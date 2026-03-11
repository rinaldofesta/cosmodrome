import Observation
import SwiftUI

@Observable
final class FontSizeState {
    var currentSize: CGFloat = 13
    var isVisible = false
}

/// Small +/- overlay for adjusting terminal font size.
/// Appears in the bottom-left corner of the terminal area, fades on idle.
struct FontSizeControlView: View {
    @Bindable var state: FontSizeState
    var onIncrease: () -> Void
    var onDecrease: () -> Void
    var onReset: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Decrease button
            Button(action: onDecrease) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Decrease font size (Cmd+-)")

            // Size label (click to reset)
            Button(action: onReset) {
                Text("\(Int(state.currentSize))pt")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(minWidth: 32, minHeight: 22)
            }
            .buttonStyle(.plain)
            .help("Reset font size (Cmd+0)")

            // Increase button
            Button(action: onIncrease) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Increase font size (Cmd+=)")
        }
        .foregroundColor(isHovered ? DS.textSecondary : DS.textTertiary)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(DS.bgSidebar.opacity(isHovered ? 0.95 : 0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .stroke(DS.borderSubtle.opacity(isHovered ? 0.6 : 0.3), lineWidth: 0.5)
                )
        )
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(Anim.quick, value: isHovered)
    }
}
