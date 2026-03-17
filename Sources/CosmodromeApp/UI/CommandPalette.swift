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

    /// Recently used commands (in-memory, up to 5).
    private var recentTitles: [String] = []
    private static let maxRecents = 5

    /// Preferred category display order. Categories not listed here appear at the end.
    private static let categoryOrder = ["Attention", "Sessions", "Projects", "Views", "Themes", "Dev Servers"]

    /// All displayable items: grouped by category (when query is empty) or flat fuzzy-matched results.
    var filteredActions: [PaletteAction] {
        if query.isEmpty {
            // Group actions by category, preserving a stable ordering
            return groupedByCategory(actions)
        }
        let words = query.lowercased()
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return groupedByCategory(actions) }

        // Score each action by fuzzy word-subsequence matching
        let scored: [(action: PaletteAction, score: Double)] = actions.compactMap { action in
            let haystack = (action.title + " " + (action.subtitle ?? "")).lowercased()
            var matched = 0
            var totalTightness: Double = 0
            for word in words {
                if let tightness = fuzzySubsequenceScore(word: word, in: haystack) {
                    matched += 1
                    totalTightness += tightness
                }
            }
            guard matched > 0 else { return nil }
            // Primary: fraction of words matched. Secondary: tightness (lower = better).
            let wordScore = Double(matched) / Double(words.count)
            let tightnessScore = matched > 0 ? totalTightness / Double(matched) : 1.0
            let combined = wordScore * 1000 - tightnessScore
            return (action, combined)
        }

        // Flat results sorted by relevance — no category headers when searching
        return scored
            .sorted { $0.score > $1.score }
            .map(\.action)
    }

    /// Groups actions by category in a stable display order.
    private func groupedByCategory(_ items: [PaletteAction]) -> [PaletteAction] {
        var buckets: [String: [PaletteAction]] = [:]
        var uncategorized: [PaletteAction] = []
        for item in items {
            if let cat = item.category {
                buckets[cat, default: []].append(item)
            } else {
                uncategorized.append(item)
            }
        }

        var result: [PaletteAction] = []
        // Known categories first, in preferred order
        for cat in Self.categoryOrder {
            if let group = buckets.removeValue(forKey: cat) {
                result.append(contentsOf: group)
            }
        }
        // Any remaining categories in alphabetical order
        for cat in buckets.keys.sorted() {
            result.append(contentsOf: buckets[cat]!)
        }
        // Uncategorized last
        result.append(contentsOf: uncategorized)
        return result
    }

    /// Recent actions to display when query is empty.
    var recentActions: [PaletteAction] {
        guard query.isEmpty, !recentTitles.isEmpty else { return [] }
        // Match recent titles to current actions list, preserving recency order
        return recentTitles.compactMap { title in
            actions.first { $0.title == title }
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
        let selected = items[selectedIndex]
        addToRecents(selected.title)
        let action = selected.action
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

    // MARK: - Recents

    private func addToRecents(_ title: String) {
        recentTitles.removeAll { $0 == title }
        recentTitles.insert(title, at: 0)
        if recentTitles.count > Self.maxRecents {
            recentTitles.removeLast()
        }
    }

    // MARK: - Fuzzy Matching

    /// Returns a tightness score (lower = tighter match) if `word` is a subsequence of `haystack`.
    /// Returns nil if no subsequence match.
    private func fuzzySubsequenceScore(word: String, in haystack: String) -> Double? {
        // Exact contains gets best score
        if haystack.contains(word) { return 0.0 }

        // Subsequence match: each character of word must appear in order in haystack
        var haystackIndex = haystack.startIndex
        var firstMatchIndex: String.Index?
        var lastMatchIndex: String.Index?
        var wordIter = word.makeIterator()
        guard var target = wordIter.next() else { return 0.0 }

        while haystackIndex < haystack.endIndex {
            if haystack[haystackIndex] == target {
                if firstMatchIndex == nil { firstMatchIndex = haystackIndex }
                lastMatchIndex = haystackIndex
                guard let next = wordIter.next() else {
                    // All characters matched — compute tightness as span / haystack length
                    let span = haystack.distance(from: firstMatchIndex!, to: lastMatchIndex!) + 1
                    return Double(span) / max(Double(haystack.count), 1.0)
                }
                target = next
            }
            haystackIndex = haystack.index(after: haystackIndex)
        }
        return nil // not all characters matched
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
                            .font(Typo.footnoteMono)
                            .foregroundColor(DS.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(DS.bgElevated)
                            )
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .background(DS.bgSurface)

                    Divider()
                        .overlay(DS.borderMedium)

                    // Results
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                // Recent section (only when query is empty)
                                let recents = state.recentActions
                                if !recents.isEmpty {
                                    PaletteSectionHeader(title: "Recent")
                                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, action in
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

                                // Main results
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
                .font(Typo.footnoteMono)
                .foregroundColor(DS.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(DS.bgElevated)
                )
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
                .font(Typo.caption)
                .fontWeight(.semibold)
                .foregroundColor(DS.textTertiary)
                .tracking(0.8)
            Rectangle()
                .fill(DS.borderSubtle)
                .frame(height: 1)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }
}

private struct PaletteRow: View {
    let action: PaletteAction
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            // State color dot — prominent, inline before icon
            if let color = action.stateColor {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Image(systemName: action.icon)
                .font(Typo.callout)
                .foregroundColor(isSelected ? DS.textPrimary : DS.textTertiary)
                .frame(width: 20)

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
            .font(Typo.captionMono)
            .fontWeight(.semibold)
            .foregroundColor(isOn ? DS.textPrimary : DS.textTertiary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? DS.accentSubtle : DS.bgHover)
            )
    }

    @ViewBuilder
    private func shortcutBadge(_ shortcut: String) -> some View {
        Text(shortcut)
            .font(Typo.footnoteMono)
            .foregroundColor(DS.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(DS.bgElevated)
            )
    }
}
