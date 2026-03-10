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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Projects")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onNewProject) {
                    Image(systemName: "plus")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Project list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projectStore.projects, id: \.id) { project in
                        let isActive = project.id == projectStore.activeProjectId

                        ProjectRow(
                            project: project,
                            isSelected: isActive,
                            onSelect: { onSelectProject(project.id) },
                            onNewSession: { onNewSession(project.id) },
                            onDelete: { onDeleteProject(project.id) }
                        )

                        // Show session thumbnails for active project
                        if isActive {
                            ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionThumbnailView(
                                    session: session,
                                    isFocused: session.id == projectStore.focusedSessionId,
                                    sessionIndex: index + 1,
                                    onSelect: { onSelectSession(session.id) },
                                    onRestart: { onRestartSession(session.id) }
                                )
                                .contextMenu {
                                    Button("Focus") { onSelectSession(session.id) }
                                    if !session.isRunning {
                                        Button("Restart") { onRestartSession(session.id) }
                                    }
                                    Divider()
                                    Button("Close Session", role: .destructive) {
                                        onCloseSession(session.id)
                                    }
                                }
                                .padding(.leading, 20)
                                .padding(.trailing, 8)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)))
    }
}

private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    var onSelect: () -> Void
    var onNewSession: () -> Void
    var onDelete: () -> Void

    @State private var isEditing = false
    @State private var editName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: project.color) ?? .blue)
                .frame(width: 8, height: 8)

            if isEditing {
                TextField("Project name", text: $editName, onCommit: {
                    commitRename()
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .focused($isNameFocused)
                .onExitCommand { cancelRename() }
                .onAppear { isNameFocused = true }
            } else {
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .gray)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(project.sessions.count)")
                .font(.system(size: 11))
                .foregroundColor(.gray)

            if project.aggregateState != .inactive {
                agentStateIndicator(project.aggregateState)
            }

            if project.attentionCount > 0 {
                Text("\(project.attentionCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }

            if isSelected {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("New Session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            startRename()
        }
        .onTapGesture(count: 1) {
            if !isEditing { onSelect() }
        }
        .contextMenu {
            Button("Rename") { startRename() }
            Divider()
            Button("New Session") { onNewSession() }
            Divider()
            Button("Delete Project", role: .destructive) { onDelete() }
        }
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
            .fill(color(for: state))
            .frame(width: 6, height: 6)
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .working: return .green
        case .needsInput: return .yellow
        case .error: return .red
        case .inactive: return .gray
        }
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
