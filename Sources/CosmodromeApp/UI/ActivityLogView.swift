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

// MARK: - "While You Were Away" Summary

private struct AwaySummary {
    let awayDuration: TimeInterval
    let tasksCompleted: Int
    let filesChanged: Int
    let needsInputCount: Int
    let errorsCount: Int
    let firstAwayEventDate: Date?
}

// MARK: - Main View

/// Activity log view showing what all agents did, grouped by session, with filtering and summary.
/// Supports two modes: compact (sidebar panel) and full (overlay).
struct ActivityLogView: View {
    let projects: [Project]
    var compact: Bool = false
    var onFocusSession: (UUID, UUID) -> Void  // (projectId, sessionId)
    var onExpand: (() -> Void)? = nil  // Compact -> full-screen
    var onDismiss: () -> Void

    @State private var timeFilter: TimeFilter = .lastHour
    @State private var eventFilter: EventFilter = .smart  // Default to Smart filter
    @State private var expandedSessions: Set<UUID> = []
    @State private var initialExpandDone = false

    // "While you were away" state
    @State private var lastInteractionTime: Date = Date()
    @State private var showAwayBanner = false
    @State private var awaySummary: AwaySummary? = nil

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
                        // "While you were away" banner
                        if showAwayBanner, let summary = awaySummary {
                            awayBanner(summary: summary)
                                .padding(.bottom, Spacing.sm)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

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
            checkAwayStatus()
        }
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                lastInteractionTime = Date()
            }
        )
    }

    // MARK: - Away Banner

    private func checkAwayStatus() {
        let now = Date()
        let awayDuration = now.timeIntervalSince(lastInteractionTime)
        guard awayDuration > 300 else { return }  // 5 minutes

        let awayStart = lastInteractionTime
        let cutoff = timeFilter.cutoff
        let effectiveStart = max(awayStart, cutoff)

        var tasks = 0
        var files = Set<String>()
        var needsInput = 0
        var errors = 0
        var firstDate: Date? = nil

        for project in projects {
            let awayEvents = project.activityLog.events.filter {
                $0.timestamp > effectiveStart && $0.timestamp <= now
            }
            for event in awayEvents {
                if firstDate == nil || event.timestamp < firstDate! {
                    firstDate = event.timestamp
                }
                switch event.kind {
                case .taskCompleted: tasks += 1
                case .fileWrite(let path, _, _): files.insert(path)
                case .error: errors += 1
                default: break
                }
            }
            // Check current session states for needsInput
            for session in project.sessions where session.isAgent {
                if session.agentState == .needsInput { needsInput += 1 }
            }
        }

        guard tasks > 0 || !files.isEmpty || needsInput > 0 || errors > 0 else { return }

        awaySummary = AwaySummary(
            awayDuration: awayDuration,
            tasksCompleted: tasks,
            filesChanged: files.count,
            needsInputCount: needsInput,
            errorsCount: errors,
            firstAwayEventDate: firstDate
        )
        withAnimation(Anim.normal) {
            showAwayBanner = true
        }
    }

    private func awayBanner(summary: AwaySummary) -> some View {
        let minutes = Int(summary.awayDuration / 60)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("While you were away (\(minutes) minutes):")
                .font(Typo.bodyMedium)
                .foregroundColor(DS.textPrimary)

            HStack(spacing: Spacing.lg) {
                if summary.tasksCompleted > 0 {
                    HStack(spacing: Spacing.xs) {
                        Text("\u{2713}")
                            .foregroundColor(DS.stateWorking)
                        Text("\(summary.tasksCompleted) \(summary.tasksCompleted == 1 ? "task" : "tasks") completed")
                            .font(Typo.body)
                            .foregroundColor(DS.textSecondary)
                    }
                }
                if summary.filesChanged > 0 {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                            .foregroundColor(DS.brand)
                        Text("\(summary.filesChanged) \(summary.filesChanged == 1 ? "file" : "files") changed")
                            .font(Typo.body)
                            .foregroundColor(DS.textSecondary)
                    }
                }
                if summary.needsInputCount > 0 {
                    HStack(spacing: Spacing.xs) {
                        Text("\u{26A0}\u{FE0F}")
                        Text("\(summary.needsInputCount) \(summary.needsInputCount == 1 ? "agent needs" : "agents need") your input")
                            .font(Typo.body)
                            .foregroundColor(DS.stateNeedsInput)
                    }
                }
                if summary.errorsCount > 0 {
                    HStack(spacing: Spacing.xs) {
                        Text("\u{274C}")
                        Text("\(summary.errorsCount) \(summary.errorsCount == 1 ? "error" : "errors")")
                            .font(Typo.body)
                            .foregroundColor(DS.stateError)
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: {
                    withAnimation(Anim.normal) {
                        showAwayBanner = false
                    }
                    lastInteractionTime = Date()
                }) {
                    Text("Dismiss")
                        .font(Typo.bodyMedium)
                        .foregroundColor(DS.textSecondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(DS.bgHover)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(DS.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .stroke(DS.borderMedium, lineWidth: 0.5)
        )
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
                color: DS.brand
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
        case minuteHeader(date: Date)
    }

    /// Convert a flat event list into display items, collapsing runs of 2+ stateChanged events
    /// and inserting minute-group headers.
    static func from(_ events: [ActivityEvent]) -> [DisplayItem] {
        var items: [DisplayItem] = []
        var stateRun: [ActivityEvent] = []
        var lastMinuteKey: String? = nil

        let minuteFormatter = DateFormatter()
        minuteFormatter.dateFormat = "HH:mm"

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
            // Insert minute header when minute changes
            let minuteKey = minuteFormatter.string(from: event.timestamp)
            if minuteKey != lastMinuteKey {
                flushRun()
                items.append(DisplayItem(id: UUID(), content: .minuteHeader(date: event.timestamp)))
                lastMinuteKey = minuteKey
            }

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
                                    withAnimation(Anim.quick) {
                                        if expandedCollapseIds.contains(item.id) {
                                            expandedCollapseIds.remove(item.id)
                                        } else {
                                            expandedCollapseIds.insert(item.id)
                                        }
                                    }
                                }
                            )
                        case .minuteHeader(let date):
                            MinuteHeaderRow(date: date, compact: compact)
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
                .frame(width: 8, height: 8)

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

            // State dot (8px)
            Circle()
                .fill(DS.stateColor(for: entry.agentState))
                .frame(width: 8, height: 8)

            // Session name
            Text(entry.sessionName)
                .font(Typo.bodyMedium)
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
                    .foregroundColor(DS.textSecondary)
            }
            if let model = entry.model {
                Text(model)
                    .font(Typo.captionMono)
                    .foregroundColor(DS.textSecondary)
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
                .foregroundColor(DS.brand.opacity(0.7))
            }

            // Event count badge
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

// MARK: - Minute Header Row

private struct MinuteHeaderRow: View {
    let date: Date
    var compact: Bool = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(timeString)
                .font(Typo.captionMono)
                .foregroundColor(DS.textTertiary)

            // Subtle divider line
            Rectangle()
                .fill(DS.borderSubtle)
                .frame(height: 0.5)
        }
        .padding(.horizontal, compact ? Spacing.sm : Spacing.md)
        .padding(.top, compact ? Spacing.xs : Spacing.sm)
        .padding(.bottom, compact ? 1 : 2)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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
                    // Time range
                    Text(timeRange)
                        .font(Typo.captionMono)
                        .foregroundColor(DS.textTertiary)
                        .frame(minWidth: compact ? 30 : 60, alignment: .trailing)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7))
                        .foregroundColor(DS.textTertiary)
                        .frame(width: compact ? 10 : 14)

                    // Recycle icon + count + dominant pattern
                    HStack(spacing: Spacing.xs) {
                        Text("\u{21BB}")
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundColor(DS.textTertiary)

                        Text("\(events.count) state transitions")
                            .font(compact ? Typo.caption : Typo.body)
                            .foregroundColor(DS.textTertiary)

                        if let pattern = dominantPattern {
                            Text("(\(pattern))")
                                .font(compact ? Typo.caption : Typo.body)
                                .foregroundColor(DS.textTertiary)
                        }
                    }

                    if !isExpanded {
                        Text("[tap to expand]")
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary.opacity(0.6))
                    }

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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Time range string showing first..last timestamp (e.g., "16:57-16:58")
    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        // Events are sorted newest-first, so last = earliest, first = latest
        let earliest = events.last?.timestamp ?? Date()
        let latest = events.first?.timestamp ?? Date()
        let startStr = formatter.string(from: earliest)
        let endStr = formatter.string(from: latest)
        if startStr == endStr {
            return startStr
        }
        return "\(startStr)-\(endStr)"
    }

    /// Detect the dominant transition pattern, e.g. "error <-> needsInput"
    private var dominantPattern: String? {
        var pairCounts: [String: Int] = [:]
        for event in events {
            if case .stateChanged(let from, let to) = event.kind {
                // Normalize the pair so A<->B and B<->A are the same
                let pair = [from.rawValue, to.rawValue].sorted().joined(separator: " \u{2194} ")
                pairCounts[pair, default: 0] += 1
            }
        }
        guard let topPair = pairCounts.max(by: { $0.value < $1.value }) else { return nil }
        // Only show if it represents a significant portion
        guard topPair.value >= events.count / 2 else { return nil }
        return topPair.key
    }
}

// MARK: - Event Row

private struct ActivityEventRow: View {
    let event: ActivityEvent
    var compact: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 4 : Spacing.sm) {
            // Icon
            Text(iconEmoji)
                .font(.system(size: compact ? 8 : 10))
                .frame(width: compact ? 14 : 18, alignment: .center)

            // Description
            Text(description)
                .font(compact ? Typo.caption : Typo.body)
                .foregroundColor(descriptionColor)
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

    /// Emoji-based icons for consistent scanability
    private var iconEmoji: String {
        switch event.kind {
        case .taskStarted: return "\u{25B6}"       // Black right-pointing triangle
        case .taskCompleted: return "\u{2713}"      // Check mark
        case .fileRead: return "\u{1F4D6}"          // Open book
        case .fileWrite: return "\u{1F4C1}"         // File folder
        case .commandRun: return "\u{26A1}"         // High voltage
        case .commandCompleted: return "\u{26A1}"   // High voltage
        case .error: return "\u{274C}"              // Cross mark
        case .modelChanged: return "\u{1F4BB}"      // Laptop
        case .stateChanged: return "\u{21BB}"       // Clockwise arrows
        case .subagentStarted: return "\u{1F50D}"   // Magnifying glass
        case .subagentCompleted: return "\u{2713}"  // Check mark
        }
    }

    /// Color for the description text matching icon semantics
    private var descriptionColor: Color {
        switch event.kind {
        case .taskStarted: return DS.stateWorking.opacity(0.7)
        case .taskCompleted: return DS.stateWorking
        case .fileRead: return DS.brand.opacity(0.7)
        case .fileWrite: return DS.brand
        case .commandRun, .commandCompleted: return Color.purple
        case .error: return DS.stateError
        case .modelChanged: return DS.textSecondary
        case .stateChanged: return DS.textTertiary
        case .subagentStarted, .subagentCompleted: return DS.textSecondary
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
