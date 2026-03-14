import Core
import SwiftUI

/// Fleet-level "Mission Control" view showing ALL agents across ALL projects.
/// Answers: "What is everyone doing right now?"
struct FleetOverviewView: View {
    @Bindable var projectStore: ProjectStore
    var onFocusSession: (UUID, UUID) -> Void  // (projectId, sessionId)
    var onDismiss: () -> Void

    @State private var filter: AgentFilter = .all
    @State private var hoveredSessionId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header: stats strip
            fleetHeader

            Divider().opacity(0.3)

            // Filter bar
            filterBar
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

            Divider().opacity(0.3)

            // Agent cards grid
            if filteredAgents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: Spacing.md) {
                        ForEach(filteredAgents, id: \.session.id) { entry in
                            AgentCardView(
                                session: entry.session,
                                projectName: entry.project.name,
                                projectColor: entry.project.color,
                                isHovered: hoveredSessionId == entry.session.id,
                                onFocus: {
                                    onFocusSession(entry.project.id, entry.session.id)
                                }
                            )
                            .onHover { isHovered in
                                hoveredSessionId = isHovered ? entry.session.id : nil
                            }
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .background(DS.bgPrimary)
    }

    // MARK: - Header

    private var fleetHeader: some View {
        HStack(spacing: Spacing.lg) {
            // Title
            HStack(spacing: Spacing.sm) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 14))
                    .foregroundColor(DS.accent)
                Text("Fleet Overview")
                    .font(Typo.title)
                    .foregroundColor(DS.textPrimary)
            }

            Spacer()

            // Stats capsules
            let counts = projectStore.fleetAgentCounts

            statCapsule(label: "\(counts.total) agents", color: DS.textSecondary)

            if counts.working > 0 {
                statCapsule(label: "\(counts.working) working", color: DS.stateWorking)
            }
            if counts.idle > 0 {
                statCapsule(label: "\(counts.idle) idle", color: DS.stateInactive)
            }
            if counts.needsInput > 0 {
                statCapsule(label: "\(counts.needsInput) input", color: DS.stateNeedsInput)
            }
            if counts.error > 0 {
                statCapsule(label: "\(counts.error) error", color: DS.stateError)
            }

            // Aggregate stats
            let tasks = projectStore.fleetTotalTasks
            let files = projectStore.fleetTotalFilesChanged
            let cost = projectStore.fleetTotalCost

            if tasks > 0 {
                statCapsule(label: "\(tasks) tasks", color: DS.textTertiary)
            }
            if files > 0 {
                statCapsule(label: "\(files) files", color: DS.textTertiary)
            }
            if cost > 0 {
                statCapsule(label: SessionStats.formatCost(cost), color: DS.textTertiary)
            }

            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(DS.bgHover)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(DS.bgSidebar)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(AgentFilter.allCases, id: \.self) { f in
                filterButton(f)
            }
            Spacer()
        }
    }

    private func filterButton(_ f: AgentFilter) -> some View {
        let count = countFor(filter: f)
        let isActive = filter == f
        return Button(action: { withAnimation(Anim.quick) { filter = f } }) {
            HStack(spacing: Spacing.xs) {
                Text(f.label)
                    .font(Typo.bodyMedium)
                if count > 0 {
                    Text("\(count)")
                        .font(Typo.caption)
                        .foregroundColor(isActive ? DS.textPrimary : DS.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.bgHover))
                }
            }
            .foregroundColor(isActive ? DS.textPrimary : DS.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isActive ? DS.bgSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundColor(DS.textTertiary)
            Text(filter == .all ? "No agents running" : "No \(filter.label.lowercased()) agents")
                .font(Typo.subheading)
                .foregroundColor(DS.textSecondary)
            Text("Start an agent session to see it here")
                .font(Typo.body)
                .foregroundColor(DS.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: Spacing.md)]
    }

    private var allAgents: [(project: Project, session: Session)] {
        projectStore.allAgentSessions.sorted { a, b in
            priorityFor(a.session.agentState) > priorityFor(b.session.agentState)
        }
    }

    private var filteredAgents: [(project: Project, session: Session)] {
        switch filter {
        case .all: return allAgents
        case .active: return allAgents.filter { $0.session.agentState == .working }
        case .idle: return allAgents.filter { $0.session.agentState == .inactive }
        case .needsInput: return allAgents.filter { $0.session.agentState == .needsInput }
        case .errors: return allAgents.filter { $0.session.agentState == .error }
        }
    }

    private func countFor(filter: AgentFilter) -> Int {
        switch filter {
        case .all: return allAgents.count
        case .active: return allAgents.count(where: { $0.session.agentState == .working })
        case .idle: return allAgents.count(where: { $0.session.agentState == .inactive })
        case .needsInput: return allAgents.count(where: { $0.session.agentState == .needsInput })
        case .errors: return allAgents.count(where: { $0.session.agentState == .error })
        }
    }

    private func priorityFor(_ state: AgentState) -> Int {
        switch state {
        case .error: return 4
        case .needsInput: return 3
        case .working: return 2
        case .inactive: return 1
        }
    }

    private func statCapsule(label: String, color: Color) -> some View {
        Text(label)
            .font(Typo.body)
            .foregroundColor(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}

// MARK: - Filter

enum AgentFilter: CaseIterable {
    case all, active, idle, needsInput, errors

    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .idle: return "Idle"
        case .needsInput: return "Needs Input"
        case .errors: return "Errors"
        }
    }
}

// MARK: - Agent Card

struct AgentCardView: View {
    let session: Session
    let projectName: String
    let projectColor: String
    let isHovered: Bool
    var onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Row 1: State dot + name + project badge
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(DS.stateColor(for: session.agentState))
                    .frame(width: 8, height: 8)
                    .shadow(color: DS.stateColor(for: session.agentState).opacity(0.4), radius: 3)

                Text(session.name)
                    .font(Typo.subheadingMedium)
                    .foregroundColor(DS.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Project badge
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(hex: projectColor) ?? .blue)
                        .frame(width: 6, height: 6)
                    Text(projectName)
                        .font(Typo.caption)
                        .foregroundColor(DS.textTertiary)
                        .lineLimit(1)
                }
            }

            // Row 2: Agent type + model + state badge
            HStack(spacing: Spacing.xs) {
                Text(session.agentType?.capitalized ?? "Agent")
                    .font(Typo.footnoteMedium)
                    .foregroundColor(DS.accent.opacity(0.8))

                if let model = session.agentModel {
                    Text("·")
                        .foregroundColor(DS.textTertiary)
                    Text(model)
                        .font(Typo.footnote)
                        .foregroundColor(DS.textTertiary)
                }

                Spacer()

                if session.stuckInfo != nil {
                    Label("stuck", systemImage: "arrow.2.circlepath")
                        .font(Typo.footnoteMedium)
                        .foregroundColor(DS.stateError)
                } else {
                    Text(stateLabel)
                        .font(Typo.footnoteMedium)
                        .foregroundColor(DS.stateColor(for: session.agentState))
                }
            }

            // Row 2b: Narrative headline
            if let narrative = session.narrative {
                Text(narrative.headline)
                    .font(Typo.footnote)
                    .foregroundColor(narrativeColor)
                    .lineLimit(2)
            }

            // Row 3: Stats — context, cost, idle duration
            HStack(spacing: Spacing.md) {
                if let ctx = session.agentContext {
                    HStack(spacing: 2) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 8))
                        Text(ctx)
                            .font(Typo.captionMono)
                    }
                    .foregroundColor(DS.textSecondary)
                }

                if let mode = session.agentMode {
                    Text(mode)
                        .font(Typo.caption)
                        .foregroundColor(DS.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(DS.bgHover)
                        .cornerRadius(Radius.sm)
                }

                Spacer()

                // Idle duration (prominent when idle)
                if session.agentState == .inactive, let idleStr = session.stats.idleDurationString {
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                        Text("idle \(idleStr)")
                            .font(Typo.captionMono)
                    }
                    .foregroundColor(idleColor)
                }

                // Cost
                let cost = session.stats.totalCost
                if cost > 0 {
                    Text(SessionStats.formatCost(cost))
                        .font(Typo.captionMono)
                        .foregroundColor(DS.textTertiary)
                }
            }

            // Row 4: Activity summary (tasks, files, commands)
            HStack(spacing: Spacing.md) {
                let stats = session.stats
                if stats.totalTasks > 0 {
                    miniStat(icon: "checkmark.circle", value: "\(stats.totalTasks)", label: "tasks")
                }
                if stats.totalFilesChanged > 0 {
                    miniStat(icon: "doc", value: "\(stats.totalFilesChanged)", label: "files")
                }
                if stats.totalCommands > 0 {
                    miniStat(icon: "terminal", value: "\(stats.totalCommands)", label: "cmds")
                }
                if stats.totalSubagents > 0 {
                    miniStat(icon: "person.2", value: "\(stats.totalSubagents)", label: "agents")
                }
                if stats.totalErrors > 0 {
                    miniStat(icon: "exclamationmark.triangle", value: "\(stats.totalErrors)", label: "errors")
                        .foregroundColor(DS.stateError.opacity(0.8))
                }

                Spacer()

                // Focus button
                Button(action: onFocus) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Focus")
                    }
                    .font(Typo.bodyMedium)
                    .foregroundColor(DS.textPrimary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(DS.accent.opacity(isHovered ? 0.5 : 0.3))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(cardBgColor)
                .animation(Anim.quick, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .stroke(cardBorderColor, lineWidth: cardBorderWidth)
                .animation(Anim.quick, value: isHovered)
                .animation(Anim.quick, value: session.agentState)
        )
    }

    // MARK: - Helpers

    private var stateLabel: String {
        switch session.agentState {
        case .working: return "working"
        case .needsInput: return "needs input"
        case .error: return "error"
        case .inactive: return "idle"
        }
    }

    /// Idle color escalates based on duration: gray → amber → red
    private var idleColor: Color {
        let idle = session.stats.currentIdleDuration
        if idle > 1800 { return DS.stateError.opacity(0.8) }   // 30min+
        if idle > 300 { return DS.stateNeedsInput.opacity(0.8) } // 5min+
        return DS.textTertiary
    }

    private var narrativeColor: Color {
        if session.stuckInfo != nil { return DS.stateError.opacity(0.9) }
        switch session.agentState {
        case .working: return DS.textSecondary
        case .needsInput: return DS.stateNeedsInput.opacity(0.9)
        case .error: return DS.stateError.opacity(0.8)
        case .inactive: return DS.textTertiary
        }
    }

    private var needsAttention: Bool {
        session.stuckInfo != nil || session.agentState == .needsInput || session.agentState == .error
    }

    private var cardBgColor: Color {
        if needsAttention {
            return DS.stateColor(for: session.agentState).opacity(0.06)
        }
        return isHovered ? DS.bgHover : DS.borderSubtle
    }

    private var cardBorderColor: Color {
        if needsAttention {
            return DS.stateColor(for: session.agentState).opacity(0.4)
        }
        return isHovered ? DS.borderMedium : DS.borderSubtle
    }

    private var cardBorderWidth: CGFloat {
        needsAttention ? 1.5 : 0.5
    }

    private func miniStat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(value)
                .font(Typo.captionMono)
        }
        .foregroundColor(DS.textTertiary)
        .help("\(value) \(label)")
    }
}
