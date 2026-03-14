import Core
import SwiftUI

// MARK: - Filter Types

enum TimeFilter: CaseIterable {
    case lastHour, today, all

    var label: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .today: return "Today"
        case .all: return "All"
        }
    }

    var cutoff: Date {
        switch self {
        case .lastHour: return Date().addingTimeInterval(-3600)
        case .today: return Calendar.current.startOfDay(for: Date())
        case .all: return .distantPast
        }
    }
}

enum EventFilter: CaseIterable {
    case smart, files, commands, errors, all

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .files: return "Files"
        case .commands: return "Commands"
        case .errors: return "Errors"
        case .all: return "All"
        }
    }

    func matches(_ kind: ActivityEvent.EventKind) -> Bool {
        switch self {
        case .smart:
            switch kind {
            case .stateChanged, .modelChanged, .taskStarted: return false
            default: return true
            }
        case .all: return true
        case .files: return kind.category == .files
        case .commands: return kind.category == .commands
        case .errors: return kind.category == .errors
        }
    }
}

// MARK: - Main View

/// Activity log view showing what all agents did, grouped by session, with filtering and summary.
/// Supports two modes: compact (sidebar panel) and full (overlay).
struct ActivityLogView: View {
    let projects: [Project]
    var compact: Bool = false
    var onFocusSession: (UUID, UUID) -> Void  // (projectId, sessionId)
    var onExpand: (() -> Void)? = nil  // Compact → full-screen
    var onDismiss: () -> Void

    @State private var timeFilter: TimeFilter = .lastHour
    @State private var eventFilter: EventFilter = .smart
    @State private var expandedSessions: Set<UUID> = []
    @State private var initialExpandDone = false

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                compactHeader
            } else {
                header
            }
            Divider().opacity(0.3)
            if !compact {
                summaryBar
                Divider().opacity(0.3)
            }
            if compact {
                compactFilterBar
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
            } else {
                filterBar
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
            }
            Divider().opacity(0.3)

            if sessionEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 2 : Spacing.sm) {
                        ForEach(sessionEntries, id: \.sessionId) { entry in
                            SessionSection(
                                entry: entry,
                                eventFilter: eventFilter,
                                compact: compact,
                                isExpanded: expandedSessions.contains(entry.sessionId),
                                onToggle: { toggleSession(entry.sessionId) },
                                onFocus: {
                                    if let pid = entry.projectId {
                                        onFocusSession(pid, entry.sessionId)
                                    }
                                }
                            )
                        }
                    }
                    .padding(compact ? Spacing.sm : Spacing.lg)
                }
            }
        }
        .background(DS.bgPrimary)
        .onAppear {
            if !initialExpandDone {
                // Auto-expand sessions that have recent activity
                expandedSessions = Set(sessionEntries.prefix(compact ? 3 : 5).map(\.sessionId))
                initialExpandDone = true
            }
        }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 11))
                .foregroundColor(DS.accent)
            Text("Activity")
                .font(Typo.subheadingMedium)
                .foregroundColor(DS.textPrimary)

            Spacer()

            Text("\(allFilteredEvents.count)")
                .font(Typo.captionMono)
                .foregroundColor(DS.textTertiary)

            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(DS.bgHover)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Expand to full screen  \u{2318}\u{21E7}L")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(DS.bgHover)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(DS.bgSidebar)
    }

    private var compactFilterBar: some View {
        HStack(spacing: 2) {
            ForEach(EventFilter.allCases, id: \.self) { ef in
                let isActive = eventFilter == ef
                Button(action: { withAnimation(Anim.quick) { eventFilter = ef } }) {
                    Text(ef.label)
                        .font(Typo.caption)
                        .foregroundColor(isActive ? DS.textPrimary : DS.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(isActive ? DS.bgSelected : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 14))
                    .foregroundColor(DS.accent)
                Text("Activity Log")
                    .font(Typo.title)
                    .foregroundColor(DS.textPrimary)
            }

            Spacer()

            // Time filter
            ForEach(TimeFilter.allCases, id: \.self) { tf in
                timeFilterButton(tf)
            }

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

    private func timeFilterButton(_ tf: TimeFilter) -> some View {
        let isActive = timeFilter == tf
        return Button(action: { withAnimation(Anim.quick) { timeFilter = tf } }) {
            Text(tf.label)
                .font(Typo.bodyMedium)
                .foregroundColor(isActive ? DS.textPrimary : DS.textTertiary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(isActive ? DS.bgSelected : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        let summary = aggregateSummary
        return HStack(spacing: Spacing.lg) {
            summaryStat(
                icon: "checkmark.circle.fill",
                value: "\(summary.tasksCompleted)",
                label: "tasks completed",
                color: DS.stateWorking
            )
            summaryStat(
                icon: "doc.fill",
                value: "\(summary.filesChanged)",
                label: "files changed",
                color: .orange
            )
            summaryStat(
                icon: "exclamationmark.triangle.fill",
                value: "\(summary.errors)",
                label: summary.errors == 1 ? "error" : "errors",
                color: summary.errors > 0 ? DS.stateError : DS.textTertiary
            )
            summaryStat(
                icon: "person.2.fill",
                value: "\(summary.activeSessions)",
                label: "sessions",
                color: DS.accent
            )

            // Total cost across all projects
            let totalCost = projects.reduce(0.0) { $0 + $1.totalCost }
            if totalCost > 0 {
                summaryStat(
                    icon: "dollarsign.circle.fill",
                    value: SessionStats.formatCost(totalCost),
                    label: "total cost",
                    color: DS.textSecondary
                )
            }

            Spacer()

            Text("\(allFilteredEvents.count) events")
                .font(Typo.footnoteMono)
                .foregroundColor(DS.textTertiary)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(DS.bgElevated)
    }

    private func summaryStat(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(value)
                .font(Typo.subheadingMedium)
                .foregroundColor(DS.textPrimary)
            Text(label)
                .font(Typo.body)
                .foregroundColor(DS.textTertiary)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(EventFilter.allCases, id: \.self) { ef in
                eventFilterButton(ef)
            }
            Spacer()

            // Expand/collapse all
            Button(action: {
                if expandedSessions.count == sessionEntries.count {
                    expandedSessions.removeAll()
                } else {
                    expandedSessions = Set(sessionEntries.map(\.sessionId))
                }
            }) {
                HStack(spacing: 2) {
                    Image(systemName: expandedSessions.count == sessionEntries.count ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 9))
                    Text(expandedSessions.count == sessionEntries.count ? "Collapse All" : "Expand All")
                        .font(Typo.body)
                }
                .foregroundColor(DS.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
        }
    }

    private func eventFilterButton(_ ef: EventFilter) -> some View {
        let isActive = eventFilter == ef
        let count = countFor(filter: ef)
        return Button(action: { withAnimation(Anim.quick) { eventFilter = ef } }) {
            HStack(spacing: Spacing.xs) {
                Text(ef.label)
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
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 40))
                .foregroundColor(DS.textTertiary)
            Text("No activity yet")
                .font(Typo.subheading)
                .foregroundColor(DS.textSecondary)
            Text("Agent events will appear here as they work")
                .font(Typo.body)
                .foregroundColor(DS.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private var allFilteredEvents: [ActivityEvent] {
        let cutoff = timeFilter.cutoff
        return projects.flatMap { project in
            project.activityLog.events.filter { event in
                event.timestamp > cutoff && eventFilter.matches(event.kind)
            }
        }
    }

    private var aggregateSummary: ActivitySummary {
        let cutoff = timeFilter.cutoff
        var tasks = 0, errors = 0, sessions = Set<UUID>()
        var files = Set<String>()

        for project in projects {
            let s = project.activityLog.summary(since: cutoff)
            tasks += s.tasksCompleted
            errors += s.errors
            files.formUnion(
                project.activityLog.events
                    .filter { $0.timestamp > cutoff }
                    .compactMap { if case .fileWrite(let p, _, _) = $0.kind { return p } else { return nil } }
            )
            sessions.formUnion(
                project.activityLog.events
                    .filter { $0.timestamp > cutoff }
                    .map(\.sessionId)
            )
        }

        return ActivitySummary(
            tasksCompleted: tasks,
            filesChanged: files.count,
            errors: errors,
            activeSessions: sessions.count,
            eventCount: allFilteredEvents.count
        )
    }

    /// Session entries sorted by most recent activity.
    private var sessionEntries: [SessionEntry] {
        let cutoff = timeFilter.cutoff

        var entries: [UUID: SessionEntry] = [:]

        for project in projects {
            let events = project.activityLog.events.filter { $0.timestamp > cutoff }
            let grouped = Dictionary(grouping: events, by: \.sessionId)

            for (sessionId, sessionEvents) in grouped {
                let filtered = sessionEvents.filter { eventFilter.matches($0.kind) }
                guard !filtered.isEmpty else { continue }

                let session = project.sessions.first(where: { $0.id == sessionId })
                let fileCount = Set(sessionEvents.compactMap {
                    if case .fileWrite(let p, _, _) = $0.kind { return p } else { return nil }
                }).count
                let cost = session?.stats.totalCost ?? 0
                let lastActivity = filtered.map(\.timestamp).max() ?? .distantPast

                entries[sessionId] = SessionEntry(
                    sessionId: sessionId,
                    projectId: project.id,
                    sessionName: session?.name ?? sessionEvents.first?.sessionName ?? "Unknown",
                    projectName: project.name,
                    agentState: session?.agentState ?? .inactive,
                    agentType: session?.agentType,
                    model: session?.agentModel,
                    cost: cost,
                    fileCount: fileCount,
                    lastActivity: lastActivity,
                    events: filtered.sorted(by: { $0.timestamp > $1.timestamp })
                )
            }
        }

        return entries.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func countFor(filter: EventFilter) -> Int {
        let cutoff = timeFilter.cutoff
        return projects.reduce(0) { total, project in
            total + project.activityLog.events.count(where: { $0.timestamp > cutoff && filter.matches($0.kind) })
        }
    }

    private func toggleSession(_ id: UUID) {
        if expandedSessions.contains(id) {
            expandedSessions.remove(id)
        } else {
            expandedSessions.insert(id)
        }
    }
}

// MARK: - Session Entry Model

private struct SessionEntry {
    let sessionId: UUID
    let projectId: UUID?
    let sessionName: String
    let projectName: String
    let agentState: AgentState
    let agentType: String?
    let model: String?
    let cost: Double
    let fileCount: Int
    let lastActivity: Date
    let events: [ActivityEvent]
}

// MARK: - Display Item (collapsing consecutive state transitions)

private struct DisplayItem: Identifiable {
    let id: UUID
    let content: Content

    enum Content {
        case event(ActivityEvent)
        case collapsed(events: [ActivityEvent])
    }

    /// Convert a flat event list into display items, collapsing runs of 2+ stateChanged events.
    static func from(_ events: [ActivityEvent]) -> [DisplayItem] {
        var items: [DisplayItem] = []
        var stateRun: [ActivityEvent] = []

        func flushRun() {
            if stateRun.count >= 2 {
                items.append(DisplayItem(id: UUID(), content: .collapsed(events: stateRun)))
            } else {
                for e in stateRun {
                    items.append(DisplayItem(id: UUID(), content: .event(e)))
                }
            }
            stateRun.removeAll()
        }

        for event in events {
            if case .stateChanged = event.kind {
                stateRun.append(event)
            } else {
                flushRun()
                items.append(DisplayItem(id: UUID(), content: .event(event)))
            }
        }
        flushRun()
        return items
    }
}

// MARK: - Session Section

private struct SessionSection: View {
    let entry: SessionEntry
    let eventFilter: EventFilter
    var compact: Bool = false
    let isExpanded: Bool
    var onToggle: () -> Void
    var onFocus: () -> Void

    @State private var isHovered = false
    @State private var expandedCollapseIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header row
            Button(action: onToggle) {
                if compact {
                    compactHeaderContent
                } else {
                    fullHeaderContent
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Event rows (when expanded)
            if isExpanded {
                let limit = compact ? 20 : 100
                let displayItems = DisplayItem.from(Array(entry.events.prefix(limit)))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayItems) { item in
                        switch item.content {
                        case .event(let event):
                            ActivityEventRow(event: event, compact: compact)
                        case .collapsed(let events):
                            CollapsedTransitionsRow(
                                events: events,
                                compact: compact,
                                isExpanded: expandedCollapseIds.contains(item.id),
                                onToggle: {
                                    if expandedCollapseIds.contains(item.id) {
                                        expandedCollapseIds.remove(item.id)
                                    } else {
                                        expandedCollapseIds.insert(item.id)
                                    }
                                }
                            )
                        }
                    }

                    if entry.events.count > limit {
                        Text("+ \(entry.events.count - limit) more")
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                            .padding(.horizontal, compact ? Spacing.sm : Spacing.lg)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .padding(.leading, compact ? Spacing.md : Spacing.xl)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: compact ? Radius.md : Radius.lg)
                .fill(isHovered ? DS.bgHover.opacity(0.5) : DS.bgElevated.opacity(0.3))
                .animation(Anim.quick, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? Radius.md : Radius.lg)
                .stroke(borderColor, lineWidth: 0.5)
        )
    }

    private var compactHeaderContent: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(DS.textTertiary)
                .frame(width: 10)

            Circle()
                .fill(DS.stateColor(for: entry.agentState))
                .frame(width: 6, height: 6)

            Text(entry.sessionName)
                .font(Typo.bodyMedium)
                .foregroundColor(DS.textPrimary)
                .lineLimit(1)

            Spacer()

            Text("\(entry.events.count)")
                .font(Typo.captionMono)
                .foregroundColor(DS.textTertiary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var fullHeaderContent: some View {
        HStack(spacing: Spacing.sm) {
            // Expand chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.textTertiary)
                .frame(width: 12)

            // State dot
            Circle()
                .fill(DS.stateColor(for: entry.agentState))
                .frame(width: 7, height: 7)

            // Session name
            Text(entry.sessionName)
                .font(Typo.subheadingMedium)
                .foregroundColor(DS.textPrimary)
                .lineLimit(1)

            // State label
            Text(stateLabel)
                .font(Typo.footnote)
                .foregroundColor(DS.stateColor(for: entry.agentState).opacity(0.8))

            // Agent type + model
            if let type = entry.agentType {
                Text(type.capitalized)
                    .font(Typo.footnote)
                    .foregroundColor(DS.textTertiary)
            }
            if let model = entry.model {
                Text(model)
                    .font(Typo.captionMono)
                    .foregroundColor(DS.textTertiary)
            }

            Spacer()

            // Stats
            if entry.cost > 0 {
                Text(SessionStats.formatCost(entry.cost))
                    .font(Typo.footnoteMono)
                    .foregroundColor(DS.textSecondary)
            }

            if entry.fileCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 8))
                    Text("\(entry.fileCount)")
                        .font(Typo.captionMono)
                }
                .foregroundColor(.orange.opacity(0.7))
            }

            Text("\(entry.events.count) events")
                .font(Typo.captionMono)
                .foregroundColor(DS.textTertiary)

            // Project badge
            Text(entry.projectName)
                .font(Typo.caption)
                .foregroundColor(DS.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(DS.bgHover)
                .cornerRadius(Radius.sm)

            // Focus button (visible on hover)
            if isHovered {
                Button(action: onFocus) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundColor(DS.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    private var stateLabel: String {
        switch entry.agentState {
        case .working: return "working"
        case .needsInput: return "needs input"
        case .error: return "error"
        case .inactive: return "idle"
        }
    }

    private var borderColor: Color {
        switch entry.agentState {
        case .needsInput, .error:
            return DS.stateColor(for: entry.agentState).opacity(0.3)
        default:
            return DS.borderSubtle
        }
    }
}

// MARK: - Collapsed Transitions Row

private struct CollapsedTransitionsRow: View {
    let events: [ActivityEvent]
    var compact: Bool = false
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: compact ? 4 : Spacing.sm) {
                    // Timestamp of first event
                    Text(timeString(events.last?.timestamp ?? Date()))
                        .font(Typo.captionMono)
                        .foregroundColor(DS.textTertiary)
                        .frame(width: compact ? 30 : 38, alignment: .trailing)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7))
                        .foregroundColor(DS.textTertiary)
                        .frame(width: compact ? 10 : 14)

                    Text("\(events.count) state transitions")
                        .font(compact ? Typo.caption : Typo.body)
                        .foregroundColor(DS.textTertiary)

                    Spacer()
                }
                .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
                .padding(.vertical, compact ? 2 : 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    ActivityEventRow(event: event, compact: compact)
                }
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Event Row

private struct ActivityEventRow: View {
    let event: ActivityEvent
    var compact: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 4 : Spacing.sm) {
            // Timestamp
            Text(timeString)
                .font(Typo.captionMono)
                .foregroundColor(DS.textTertiary)
                .frame(width: compact ? 30 : 38, alignment: .trailing)

            // Icon
            Image(systemName: iconName)
                .font(.system(size: compact ? 8 : 9))
                .foregroundColor(iconColor)
                .frame(width: compact ? 10 : 14)

            // Description
            Text(description)
                .font(compact ? Typo.caption : Typo.body)
                .foregroundColor(DS.textPrimary.opacity(0.85))
                .lineLimit(compact ? 1 : 2)

            Spacer()
        }
        .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isHovered ? DS.bgHover : Color.clear)
                .animation(Anim.quick, value: isHovered)
        )
        .onHover { isHovered = $0 }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: event.timestamp)
    }

    private var iconName: String {
        switch event.kind {
        case .taskStarted: return "play.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .fileRead: return "doc"
        case .fileWrite: return "doc.fill"
        case .commandRun: return "terminal"
        case .error: return "exclamationmark.triangle.fill"
        case .modelChanged: return "cpu"
        case .stateChanged: return "arrow.right"
        case .subagentStarted: return "arrow.triangle.branch"
        case .subagentCompleted: return "checkmark.diamond"
        case .commandCompleted: return "terminal.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .taskStarted: return DS.stateWorking
        case .taskCompleted: return DS.stateWorking
        case .fileRead: return .blue
        case .fileWrite: return .orange
        case .commandRun: return .cyan
        case .error: return DS.stateError
        case .modelChanged: return .purple
        case .stateChanged: return DS.textTertiary
        case .subagentStarted: return .teal
        case .subagentCompleted: return .teal
        case .commandCompleted: return .mint
        }
    }

    private var description: String {
        switch event.kind {
        case .taskStarted:
            return "Started working"
        case .taskCompleted(let duration):
            return "Task completed (\(SessionStats.formatDuration(duration)))"
        case .fileRead(let path):
            return "Read \(shortenPath(path))"
        case .fileWrite(let path, let added, let removed):
            var s = shortenPath(path)
            if let a = added, let r = removed {
                s += " +\(a) -\(r)"
            }
            return s
        case .commandRun(let command):
            return truncate(command, max: 60)
        case .error(let message):
            return truncate(message, max: 80)
        case .modelChanged(let model):
            return "Model: \(model)"
        case .stateChanged(let from, let to):
            return "\(from.rawValue) \u{2192} \(to.rawValue)"
        case .subagentStarted(let name, let desc):
            let d = desc.isEmpty ? "" : " \u{2014} \(truncate(desc, max: 40))"
            return "Agent: \(name)\(d)"
        case .subagentCompleted(let name, let duration):
            return "Agent done: \(name) (\(SessionStats.formatDuration(duration)))"
        case .commandCompleted(let command, let exitCode, let duration):
            let cmd = truncate(command ?? "command", max: 40)
            let exit = exitCode.map { $0 == 0 ? " \u{2713}" : " [exit \($0)]" } ?? ""
            return "\(cmd)\(exit) (\(SessionStats.formatDuration(duration)))"
        }
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 3 { return path }
        return components.suffix(3).joined(separator: "/")
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\u{2026}"
    }
}
