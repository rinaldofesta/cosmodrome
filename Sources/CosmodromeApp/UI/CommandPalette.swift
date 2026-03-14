import AppKit
import Core
import SwiftUI

/// Action entry in the command palette.
struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let category: String?
    let isToggle: Bool
    let toggleState: Bool
    let stateColor: Color?
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, icon: String = "terminal",
         shortcut: String? = nil, category: String? = nil,
         isToggle: Bool = false, toggleState: Bool = false,
         stateColor: Color? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.shortcut = shortcut
        self.category = category
        self.isToggle = isToggle
        self.toggleState = toggleState
        self.stateColor = stateColor
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
                // Tap-to-dismiss area
                DS.overlay
                    .contentShape(Rectangle())
                    .onTapGesture { state.dismiss() }

                // Palette bar flush at top
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "magnifyingglass")
                            .font(Typo.title)
                            .foregroundColor(DS.textTertiary)
                        TextField("Search commands, projects, sessions...", text: $state.query)
                            .textFieldStyle(.plain)
                            .font(Typo.largeTitle)
                            .foregroundColor(DS.textPrimary)
                            .onSubmit { state.confirm() }
                        if !state.query.isEmpty {
                            Button(action: { state.query = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(Typo.callout)
                                    .foregroundColor(DS.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("esc")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(DS.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(DS.bgHover)
                            )
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)

                    Divider().opacity(0.2)

                    // Results
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                let items = state.filteredActions
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                                    // Category header (show when category changes and query is empty)
                                    if state.query.isEmpty,
                                       let cat = action.category,
                                       (index == 0 || items[index - 1].category != cat) {
                                        PaletteSectionHeader(title: cat)
                                    }

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
                        .frame(maxHeight: 400)
                        .onChange(of: state.selectedIndex) { _, newIndex in
                            let items = state.filteredActions
                            if newIndex >= 0 && newIndex < items.count {
                                withAnimation(Anim.quick) {
                                    proxy.scrollTo(items[newIndex].id, anchor: .center)
                                }
                            }
                        }
                    }

                    // Footer hint
                    HStack(spacing: Spacing.lg) {
                        keyHint("↑↓", label: "navigate")
                        keyHint("↵", label: "select")
                        keyHint("esc", label: "dismiss")
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.bgSidebar.opacity(0.5))
                }
                .background(DS.bgElevated)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: Radius.lg,
                        bottomTrailingRadius: Radius.lg, topTrailingRadius: 0
                    )
                )
                .shadow(color: DS.shadowHeavy, radius: 20, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(DS.bgHover))
            Text(label)
                .font(Typo.footnote)
                .foregroundColor(DS.textTertiary)
        }
    }
}

private struct PaletteSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .default))
                .foregroundColor(DS.textTertiary)
                .tracking(0.8)
            Rectangle()
                .fill(DS.borderSubtle)
                .frame(height: 1)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xs)
    }
}

private struct PaletteRow: View {
    let action: PaletteAction
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Image(systemName: action.icon)
                    .font(Typo.callout)
                    .foregroundColor(isSelected ? DS.textPrimary : DS.textTertiary)
                    .frame(width: 20)

                if let color = action.stateColor {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .offset(x: 8, y: -6)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(Typo.subheading)
                    .foregroundColor(DS.textPrimary)

                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(Typo.footnote)
                        .foregroundColor(DS.textTertiary)
                }
            }

            Spacer()

            if action.isToggle {
                togglePill(isOn: action.toggleState)
            }

            if let shortcut = action.shortcut {
                shortcutBadge(shortcut)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(isSelected ? DS.bgSelected : (isHovered ? DS.bgHover : Color.clear))
                .animation(Anim.quick, value: isSelected)
                .animation(Anim.quick, value: isHovered)
                .padding(.horizontal, Spacing.sm)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func togglePill(isOn: Bool) -> some View {
        Text(isOn ? "ON" : "OFF")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(isOn ? DS.textPrimary : DS.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? DS.accentSubtle : DS.bgHover)
            )
    }

    @ViewBuilder
    private func shortcutBadge(_ shortcut: String) -> some View {
        Text(shortcut)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(DS.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(DS.bgHover)
            )
    }
}
