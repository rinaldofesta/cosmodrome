import AppKit
import Core
import SwiftUI

/// Action entry in the command palette.
struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let isToggle: Bool
    let toggleState: Bool
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, icon: String = "terminal",
         isToggle: Bool = false, toggleState: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isToggle = isToggle
        self.toggleState = toggleState
        self.action = action
    }
}

/// Observable state for the command palette.
@Observable
final class CommandPaletteState {
    var isVisible = false
    var query = ""
    var actions: [PaletteAction] = []
    var selectedIndex = 0
    var onDismiss: (() -> Void)?

    var filteredActions: [PaletteAction] {
        if query.isEmpty { return actions }
        let q = query.lowercased()
        return actions.filter { action in
            action.title.lowercased().contains(q) ||
            (action.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    func show(actions: [PaletteAction]) {
        self.actions = actions
        self.query = ""
        self.selectedIndex = 0
        self.isVisible = true
    }

    func dismiss() {
        isVisible = false
        query = ""
        onDismiss?()
    }

    func confirm() {
        let items = filteredActions
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let action = items[selectedIndex].action
        dismiss()
        action()
    }

    func moveUp() {
        let count = filteredActions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    func moveDown() {
        let count = filteredActions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }
}

/// SwiftUI view for the command palette — full-width bar at top of content area.
struct CommandPaletteView: View {
    @Bindable var state: CommandPaletteState

    var body: some View {
        if state.isVisible {
            ZStack(alignment: .top) {
                // Tap-to-dismiss area (no dimming)
                Color.black.opacity(0.15)
                    .contentShape(Rectangle())
                    .onTapGesture { state.dismiss() }

                // Palette bar flush at top
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        TextField("Type a command...", text: $state.query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .onSubmit { state.confirm() }
                        if !state.query.isEmpty {
                            Button(action: { state.query = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("esc")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().opacity(0.3)

                    // Results
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(state.filteredActions.enumerated()), id: \.element.id) { index, action in
                                    PaletteRow(
                                        action: action,
                                        isSelected: index == state.selectedIndex
                                    )
                                    .id(action.id)
                                    .onTapGesture {
                                        state.selectedIndex = index
                                        state.confirm()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: state.selectedIndex) { _, newIndex in
                            let items = state.filteredActions
                            if newIndex >= 0 && newIndex < items.count {
                                proxy.scrollTo(items[newIndex].id)
                            }
                        }
                    }
                }
                .background(Color(white: 0.11))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 8,
                        bottomTrailingRadius: 8, topTrailingRadius: 0
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PaletteRow: View {
    let action: PaletteAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .gray)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundColor(.white)

                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            if action.isToggle {
                togglePill(isOn: action.toggleState)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private func togglePill(isOn: Bool) -> some View {
        Text(isOn ? "ON" : "OFF")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(isOn ? .white : .gray)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08))
            )
    }
}
