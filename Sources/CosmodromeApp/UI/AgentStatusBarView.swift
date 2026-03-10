import Core
import SwiftUI

struct AgentStatusBarView: View {
    @Bindable var projectStore: ProjectStore
    var onJumpToSession: (UUID, UUID) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(agentEntries, id: \.sessionId) { entry in
                AgentStatusEntry(
                    projectName: entry.projectName,
                    sessionName: entry.sessionName,
                    state: entry.state,
                    model: entry.model
                )
                .onTapGesture {
                    onJumpToSession(entry.projectId, entry.sessionId)
                }
            }

            Spacer()

            // Session count
            Text("\(totalSessionCount) sessions")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)))
    }

    private struct AgentInfo: Identifiable {
        let id = UUID()
        let projectId: UUID
        let projectName: String
        let sessionId: UUID
        let sessionName: String
        let state: AgentState
        let model: String?
    }

    private var agentEntries: [AgentInfo] {
        projectStore.projects.flatMap { project in
            project.sessions
                .filter { $0.isAgent && $0.agentState != .inactive }
                .map { session in
                    AgentInfo(
                        projectId: project.id,
                        projectName: project.name,
                        sessionId: session.id,
                        sessionName: session.name,
                        state: session.agentState,
                        model: session.agentModel
                    )
                }
        }
    }

    private var totalSessionCount: Int {
        projectStore.projects.reduce(0) { $0 + $1.sessions.count }
    }
}

private struct AgentStatusEntry: View {
    let projectName: String
    let sessionName: String
    let state: AgentState
    let model: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(stateColor.opacity(0.15))
        )
    }

    private var statusText: String {
        var text = "\(projectName)/\(sessionName)"
        if let model {
            text += " \(model)"
        }
        let stateLabel: String
        switch state {
        case .working: stateLabel = "working"
        case .needsInput: stateLabel = "input"
        case .error: stateLabel = "error"
        case .inactive: stateLabel = ""
        }
        if !stateLabel.isEmpty {
            text += " \(stateLabel)"
        }
        return text
    }

    private var stateColor: Color {
        switch state {
        case .working: return .green
        case .needsInput: return .yellow
        case .error: return .red
        case .inactive: return .gray
        }
    }
}
