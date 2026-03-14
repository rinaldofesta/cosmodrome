import Core
import SwiftUI

struct AgentStatusBarView: View {
    @Bindable var projectStore: ProjectStore
    var onJumpToSession: (UUID, UUID) -> Void
    var onToggleActivityLog: () -> Void
    var onToggleFleetView: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(agentEntries, id: \.sessionId) { entry in
                AgentStatusEntry(
                    displayLabel: displayLabel(for: entry),
                    sessionName: entry.sessionName,
                    state: entry.state,
                    model: entry.model,
                    branch: entry.branch,
                    narrativeHeadline: entry.narrativeHeadline,
                    isStuck: entry.isStuck,
                    isFocused: entry.sessionId == projectStore.focusedSessionId
                )
                .onTapGesture {
                    onJumpToSession(entry.projectId, entry.sessionId)
                }
            }

            Spacer()

            // Fleet summary — shapes + colors for color-blind accessibility
            let counts = projectStore.fleetAgentCounts
            if counts.total > 0 {
                HStack(spacing: Spacing.sm) {
                    if counts.working > 0 {
                        fleetIndicator(symbol: "\u{25CF}", count: counts.working, color: DS.stateWorking)
                    }
                    if counts.needsInput > 0 {
                        fleetIndicator(symbol: "\u{25D0}", count: counts.needsInput, color: DS.stateNeedsInput)
                    }
                    if counts.error > 0 {
                        fleetIndicator(symbol: "\u{25B2}", count: counts.error, color: DS.stateError)
                    }

                    Text("\(totalSessionCount) sessions")
                        .font(Typo.footnote)
                        .foregroundColor(DS.textTertiary)
                }
            }

            // Total cost
            let cost = projectStore.fleetTotalCost
            if cost > 0 {
                Text(SessionStats.formatCost(cost))
                    .font(Typo.captionMono)
                    .foregroundColor(DS.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bgPrimary)
    }

    // MARK: - Display Label Logic

    /// When only one project is open, show just the session name.
    /// When multiple projects are open, abbreviate the project name to max 6 chars.
    private func displayLabel(for entry: AgentInfo) -> String {
        let projectCount = projectStore.projects.count
        if projectCount <= 1 {
            return entry.sessionName
        }
        let abbreviated = entry.projectName.count > 6
            ? String(entry.projectName.prefix(6))
            : entry.projectName
        return "\(abbreviated)/\(entry.sessionName)"
    }

    // MARK: - Fleet Indicator

    private func fleetIndicator(symbol: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(symbol)
                .font(.system(size: 9))
            Text("\(count)")
                .font(Typo.footnoteMono)
        }
        .foregroundColor(color)
    }

    // MARK: - Data

    private struct AgentInfo: Identifiable {
        let id = UUID()
        let projectId: UUID
        let projectName: String
        let sessionId: UUID
        let sessionName: String
        let state: AgentState
        let model: String?
        let branch: String?
        let narrativeHeadline: String?
        let isStuck: Bool
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
                        model: session.agentModel,
                        branch: session.gitBranch,
                        narrativeHeadline: session.narrative?.headline,
                        isStuck: session.stuckInfo != nil
                    )
                }
        }
    }

    private var totalSessionCount: Int {
        projectStore.projects.reduce(0) { $0 + $1.sessions.count }
    }
}

// MARK: - Agent Status Entry (Tab)

private struct AgentStatusEntry: View {
    let displayLabel: String
    let sessionName: String
    let state: AgentState
    let model: String?
    let branch: String?
    let narrativeHeadline: String?
    let isStuck: Bool
    let isFocused: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Top border — 2px state-colored line for focused tab
            Rectangle()
                .fill(isFocused ? DS.stateColor(for: state) : Color.clear)
                .frame(height: 2)

            HStack(spacing: Spacing.xs) {
                // State dot — 8px focused, 6px inactive at 70% opacity
                Circle()
                    .fill(DS.stateColor(for: state))
                    .frame(width: isFocused ? 8 : 6, height: isFocused ? 8 : 6)
                    .opacity(isFocused ? 1.0 : 0.7)

                Text(statusText)
                    .font(Typo.body)
                    .foregroundColor(isFocused ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)

                if let branch {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7))
                        Text(branch)
                            .font(Typo.captionMono)
                            .lineLimit(1)
                    }
                    .foregroundColor(DS.textTertiary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(tabBackground)
                .animation(Anim.quick, value: isHovered)
                .animation(Anim.quick, value: isFocused)
        )
        .onHover { isHovered = $0 }
        .help("\(displayLabel)\(branch.map { " (\($0))" } ?? "")")
    }

    private var tabBackground: Color {
        if isFocused {
            return DS.bgSurface
        }
        if isHovered {
            return DS.bgHover
        }
        return Color.clear
    }

    private var statusText: String {
        // Prefer narrative headline when available
        if let headline = narrativeHeadline {
            return "\(displayLabel) \u{2014} \(headline)"
        }
        var text = displayLabel
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
}

// MARK: - Status Bar Button (unused but kept for potential future use)

private struct StatusBarButton: View {
    let icon: String
    let label: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isHovered ? DS.textPrimary : DS.textTertiary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isHovered ? DS.bgHover : Color.clear)
                .animation(Anim.quick, value: isHovered)
        )
        .onHover { isHovered = $0 }
        .help("\(label)  \(shortcut)")
    }
}
