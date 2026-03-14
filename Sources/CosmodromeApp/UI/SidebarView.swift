import Core
import SwiftUI

struct SidebarView: View {
    @Bindable var projectStore: ProjectStore
    var onSelectProject: (UUID) -> Void
    var onSelectSession: (UUID) -> Void
    var onNewProject: () -> Void
    var onNewSession: (UUID) -> Void
    var onDeleteProject: (UUID) -> Void
    var onCloseSession: (UUID) -> Void
    var onRestartSession: (UUID) -> Void
    var onToggleActivityLog: () -> Void
    var onToggleFleetView: () -> Void
    var onToggleCommandPalette: () -> Void

    @State private var expandedProjectIds: Set<UUID> = []
    @State private var didInitExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Projects")
                    .font(Typo.title)
                    .foregroundColor(DS.textPrimary)
                Spacer()
                Button(action: onNewProject) {
                    Image(systemName: "plus")
                        .font(Typo.callout)
                        .foregroundColor(DS.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            Divider().opacity(0.3)

            // Project list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projectStore.projects, id: \.id) { project in
                        let isActive = project.id == projectStore.activeProjectId
                        let isExpanded = expandedProjectIds.contains(project.id)

                        ProjectRow(
                            project: project,
                            isSelected: isActive,
                            isExpanded: isExpanded,
                            onSelect: {
                                // Toggle expand/collapse independently
                                withAnimation(Anim.quick) {
                                    if expandedProjectIds.contains(project.id) {
                                        expandedProjectIds.remove(project.id)
                                    } else {
                                        expandedProjectIds.insert(project.id)
                                    }
                                }
                            },
                            onNewSession: { onNewSession(project.id) },
                            onDelete: { onDeleteProject(project.id) }
                        )

                        // Show session thumbnails for expanded projects
                        if isExpanded {
                            ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionThumbnailView(
                                    session: session,
                                    isFocused: session.id == projectStore.focusedSessionId,
                                    sessionIndex: index + 1,
                                    onSelect: {
                                        // Activate the project if needed, then focus the session
                                        if project.id != projectStore.activeProjectId {
                                            onSelectProject(project.id)
                                        }
                                        onSelectSession(session.id)
                                    },
                                    onRestart: { onRestartSession(session.id) }
                                )
                                .contextMenu {
                                    Button("Focus") {
                                        if project.id != projectStore.activeProjectId {
                                            onSelectProject(project.id)
                                        }
                                        onSelectSession(session.id)
                                    }
                                    if !session.isRunning {
                                        Button("Restart") { onRestartSession(session.id) }
                                    }
                                    Divider()
                                    Button("Close Session", role: .destructive) {
                                        onCloseSession(session.id)
                                    }
                                }
                                .padding(.leading, 20)
                                .padding(.trailing, Spacing.sm)
                                .padding(.vertical, 1)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)
            }

            // Bottom toolbar
            Divider().opacity(0.3)

            SidebarToolbar(
                onToggleActivityLog: onToggleActivityLog,
                onToggleFleetView: onToggleFleetView,
                onToggleCommandPalette: onToggleCommandPalette
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bgSidebar)
        .onAppear {
            if !didInitExpanded {
                // Start with the active project expanded
                if let id = projectStore.activeProjectId {
                    expandedProjectIds.insert(id)
                } else if let first = projectStore.projects.first {
                    expandedProjectIds.insert(first.id)
                }
                didInitExpanded = true
            }
        }
    }
}

// MARK: - Sidebar Toolbar

private struct SidebarToolbar: View {
    var onToggleActivityLog: () -> Void
    var onToggleFleetView: () -> Void
    var onToggleCommandPalette: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            SidebarToolbarButton(
                icon: "list.bullet.rectangle",
                label: "Activity Log",
                shortcut: "\u{2318}L",
                action: onToggleActivityLog
            )

            SidebarToolbarButton(
                icon: "square.grid.2x2",
                label: "Fleet Overview",
                shortcut: "\u{2318}\u{21E7}F",
                action: onToggleFleetView
            )

            Spacer()

            SidebarToolbarButton(
                icon: "magnifyingglass",
                label: "Command Palette",
                shortcut: "\u{2318}P",
                action: onToggleCommandPalette
            )
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
    }
}

private struct SidebarToolbarButton: View {
    let icon: String
    let label: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isHovered ? DS.textPrimary : DS.textTertiary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isHovered ? DS.bgHover : Color.clear)
                .animation(Anim.quick, value: isHovered)
        )
        .onHover { isHovered = $0 }
        .help("\(label)  \(shortcut)")
    }
}

// MARK: - Color Presets

private let projectColorPresets: [(name: String, hex: String)] = [
    ("Blue", "#4A90D9"),
    ("Red", "#E74C3C"),
    ("Green", "#2ECC71"),
    ("Orange", "#F39C12"),
    ("Purple", "#9B59B6"),
    ("Teal", "#1ABC9C"),
    ("Pink", "#E91E63"),
    ("Slate", "#607D8B"),
]

private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let isExpanded: Bool
    var onSelect: () -> Void
    var onNewSession: () -> Void
    var onDelete: () -> Void

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isHovered = false
    @State private var showColorPicker = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(DS.textTertiary)
                .frame(width: 10)

            Circle()
                .fill(Color(hex: project.color) ?? .blue)
                .frame(width: 8, height: 8)
                .onTapGesture { showColorPicker.toggle() }
                .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
                    colorPickerPopover
                }

            if isEditing {
                AutoSelectTextField(text: $editName, onCommit: commitRename)
                    .font(Typo.subheading)
                    .foregroundColor(DS.textPrimary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 2)
                    .background(DS.bgHover)
                    .cornerRadius(Radius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .stroke(DS.borderFocus, lineWidth: 1)
                    )
                    .onExitCommand { cancelRename() }
            } else {
                Text(project.name)
                    .font(Typo.subheading)
                    .foregroundColor(isSelected ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(project.sessions.count)")
                .font(Typo.captionMono)
                .foregroundColor(DS.textSecondary)

            if project.aggregateState != .inactive {
                agentStateIndicator(project.aggregateState)
            }

            if project.attentionCount > 0 {
                Text("\(project.attentionCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.stateError))
            }

            if isSelected || isHovered {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(Typo.body)
                        .foregroundColor(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("New Session")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(isSelected ? DS.bgSelected : (isHovered ? DS.bgHover : Color.clear))
                .animation(Anim.quick, value: isSelected)
                .animation(Anim.quick, value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            startRename()
        }
        .onTapGesture(count: 1) {
            if !isEditing { onSelect() }
        }
        .contextMenu {
            Button("Rename") { startRename() }
            Button("Change Color") { showColorPicker = true }
            Divider()
            Button("New Shell Session") { onNewSession() }
            Divider()
            Button("Delete Project", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var colorPickerPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Project Color")
                .font(Typo.caption)
                .foregroundColor(DS.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], spacing: 6) {
                ForEach(projectColorPresets, id: \.hex) { preset in
                    let isCurrentColor = project.color == preset.hex
                    Circle()
                        .fill(Color(hex: preset.hex) ?? .blue)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: isCurrentColor ? 2 : 0)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .onTapGesture {
                            project.color = preset.hex
                            showColorPicker = false
                        }
                        .help(preset.name)
                }
            }
        }
        .padding(Spacing.md)
        .frame(width: 140)
    }

    private func startRename() {
        editName = project.name
        isEditing = true
    }

    private func commitRename() {
        if !editName.trimmingCharacters(in: .whitespaces).isEmpty {
            project.name = editName.trimmingCharacters(in: .whitespaces)
        }
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    @ViewBuilder
    private func agentStateIndicator(_ state: AgentState) -> some View {
        Circle()
            .fill(DS.stateColor(for: state))
            .frame(width: 6, height: 6)
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") {
            hexStr.removeFirst()
        }
        guard hexStr.count == 6,
              let value = UInt64(hexStr, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
