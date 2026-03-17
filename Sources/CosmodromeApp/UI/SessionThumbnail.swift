import AppKit
import Core
import SwiftUI

struct SessionThumbnailView: View {
    let session: Session
    let isFocused: Bool
    let sessionIndex: Int
    var onSelect: () -> Void = {}
    var onRestart: () -> Void = {}
    let maxLines: Int = 4
    let maxCols: Int = 40

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isHovered = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Colored left border strip — primary state indicator
            RoundedRectangle(cornerRadius: 1.5)
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 0) {
            // Row 1: Name + session index
            HStack(spacing: Spacing.sm) {
                if isEditing {
                    AutoSelectTextField(text: $editName, onCommit: commitRename)
                        .font(Typo.footnoteMedium)
                        .foregroundColor(DS.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(DS.bgHover)
                        .cornerRadius(Radius.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .stroke(DS.borderFocus, lineWidth: 1)
                        )
                        .onExitCommand { isEditing = false }
                } else {
                    Text(session.name)
                        .font(Typo.footnoteMedium)
                        .foregroundColor(isFocused ? DS.textPrimary : DS.textSecondary)
                        .lineLimit(1)
                    if session.isOrphaned {
                        Text("(orphaned)")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateOrphaned)
                    }
                }

                // Unread state change dot
                if !isFocused && session.hasUnreadStateChange {
                    Circle()
                        .fill(DS.brand)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer(minLength: 4)

                // Notification badge
                if session.hasUnreadNotification {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8))
                        .foregroundColor(DS.stateNeedsInput)
                        .transition(.scale.combined(with: .opacity))
                }

                // Session index (subtle, right side)
                Text("\(sessionIndex)")
                    .font(Typo.captionMono)
                    .foregroundColor(DS.textTertiary)
                    .frame(minWidth: 12, alignment: .trailing)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, 4)

            // Row 2: Subtitle — agent + model + context percentage (consolidated)
            HStack(spacing: Spacing.xs) {
                if session.isAgent {
                    Text(session.agentType?.capitalized ?? "Agent")
                        .font(Typo.caption)
                        .foregroundColor(DS.accent.opacity(0.8))
                    if let model = session.agentModel {
                        Text("\u{00B7}")
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                        Text(model)
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                    }
                    // Context percentage (just the number, no effort label)
                    if let context = session.agentContext {
                        Text("\u{00B7}")
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                        Text(context)
                            .font(Typo.captionMono)
                            .foregroundColor(DS.textSecondary)
                    }
                } else {
                    let cmdName = (session.command as NSString).lastPathComponent
                    Text(cmdName)
                        .font(Typo.caption)
                        .foregroundColor(DS.textTertiary)
                }

                if let branch = session.gitBranch {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7))
                        Text(branch)
                            .font(Typo.captionMono)
                            .lineLimit(1)
                    }
                    .foregroundColor(DS.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, 4)

            // Row 3: State badge — prominent, colored
            if session.isAgent {
                HStack(spacing: Spacing.xs) {
                    if session.stuckInfo != nil {
                        Label("stuck", systemImage: "arrow.2.circlepath")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateError)
                            .transition(.opacity)
                    } else if session.agentState == .needsInput {
                        Label("needs input", systemImage: "exclamationmark.bubble.fill")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateNeedsInput)
                            .transition(.opacity)
                    } else if session.agentState == .error {
                        Label("error", systemImage: "exclamationmark.triangle.fill")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateError)
                            .transition(.opacity)
                    } else if session.agentState == .working {
                        Label("working", systemImage: "circle.fill")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateWorking)
                            .transition(.opacity)
                    } else if session.agentState == .inactive,
                              let idleStr = session.stats.idleDurationString {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 8))
                            Text("idle \(idleStr)")
                                .font(Typo.caption)
                        }
                        .foregroundColor(idleWarningColor)
                    }

                    if session.exitedUnexpectedly && !session.isAgent {
                        Label("exited", systemImage: "exclamationmark.triangle.fill")
                            .font(Typo.caption)
                            .foregroundColor(DS.stateError.opacity(0.8))
                    }

                    Spacer()

                    if let cost = session.agentCost {
                        Text(cost)
                            .font(Typo.captionMono)
                            .foregroundColor(DS.textTertiary)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 4)
            } else if session.exitedUnexpectedly {
                HStack(spacing: Spacing.xs) {
                    Label("exited", systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.caption)
                        .foregroundColor(DS.stateError.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 4)
            }

            // Row 4: Narrative — show interpretation when available, else headline
            if session.isAgent, let narrative = session.narrative {
                Text(narrative.interpretation ?? narrative.headline)
                    .font(Typo.caption)
                    .foregroundColor(narrativeColor)
                    .lineLimit(2)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 4)
            }

            // Row 5: Detected ports
            if !session.detectedPorts.isEmpty {
                HStack(spacing: Spacing.xs) {
                    ForEach(session.detectedPorts, id: \.self) { port in
                        Button(action: {
                            if let url = URL(string: "http://localhost:\(port)") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "network")
                                    .font(.system(size: 7))
                                Text(":\(port)")
                                    .font(Typo.captionMono)
                            }
                            .foregroundColor(DS.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(DS.accentSubtle)
                            .cornerRadius(Radius.sm)
                        }
                        .buttonStyle(.plain)
                        .help("Open http://localhost:\(port)")
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 3)
            }

            // Row 6: Terminal preview for non-agent sessions
            if !session.isAgent, let backend = session.backend {
                let preview = buildPreview(backend: backend)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(DS.textTertiary.opacity(0.7))
                        .lineLimit(maxLines)
                        .padding(.horizontal, Spacing.md)
                        .padding(.bottom, Spacing.md)
                }
            }

            // Bottom padding for agent sessions
            if session.isAgent {
                Spacer().frame(height: Spacing.sm)
            }
            } // end inner VStack
        } // end HStack with left border
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(cardBackgroundColor)
                .animation(Anim.quick, value: isFocused)
                .animation(Anim.quick, value: isHovered)
                .animation(Anim.quick, value: session.agentState)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .stroke(attentionBorderColor, lineWidth: attentionBorderWidth)
                .animation(Anim.quick, value: isFocused)
                .animation(Anim.quick, value: isHovered)
                .animation(Anim.quick, value: session.agentState)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .contentShape(Rectangle())
        .opacity(isFocused ? 1.0 : 0.65)
        .animation(Anim.quick, value: isFocused)
        .animation(Anim.quick, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            startRename()
        }
        .onTapGesture(count: 1) {
            if !isEditing { onSelect() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts: [String] = ["Session \(session.name)"]
        if session.isAgent {
            parts.append(session.agentType?.capitalized ?? "Agent")
            if let model = session.agentModel {
                parts.append(model)
            }
            switch session.agentState {
            case .working: parts.append("working")
            case .needsInput: parts.append("needs input")
            case .error: parts.append("error")
            case .inactive: parts.append("inactive")
            }
            if let context = session.agentContext {
                parts.append(context)
            }
        }
        return parts.joined(separator: ", ")
    }

    private func startRename() {
        editName = session.name
        isEditing = true
    }

    private func commitRename() {
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { session.name = trimmed }
        isEditing = false
    }

    /// Card background: focused card gets a subtle state-color tint, otherwise standard hover/clear
    private var cardBackgroundColor: Color {
        if isFocused && session.isAgent && session.agentState != .inactive {
            // Focused agent session: use dimmed state color at ~8-10% opacity
            return DS.stateColorDim(for: session.agentState).opacity(0.45)
            // stateColorDim is already 20%, 0.45 brings it to ~9%
        }
        if isFocused {
            return DS.bgSelected
        }
        if isHovered {
            return DS.bgHover
        }
        return Color.clear
    }

    private var urgencyLevel: UrgencyScorer.Level {
        session.narrative?.urgency?.level ?? .none
    }

    private var attentionBorderColor: Color {
        switch urgencyLevel {
        case .critical: return DS.stateError.opacity(0.6)
        case .high: return DS.stateNeedsInput.opacity(0.5)
        case .medium: return DS.stateColor(for: session.agentState).opacity(0.3)
        default: break
        }
        return isFocused ? DS.borderFocus : (isHovered ? DS.borderMedium : DS.borderSubtle)
    }

    private var attentionBorderWidth: CGFloat {
        if urgencyLevel >= .high { return 1.5 }
        return isFocused ? 1.5 : 0.5
    }

    /// Whether this session needs attention — driven by urgency score.
    private var needsAttention: Bool {
        session.isAgent && urgencyLevel >= .medium
    }

    /// Color for the narrative text — driven by urgency level.
    private var narrativeColor: Color {
        switch urgencyLevel {
        case .critical: return DS.stateError
        case .high: return DS.stateNeedsInput.opacity(0.9)
        case .medium: return DS.textSecondary
        case .low, .none:
            if session.agentState == .inactive { return DS.textTertiary }
            return DS.textSecondary
        }
    }

    /// Idle color escalates: gray (< 5min) -> amber (5-30min) -> red (30min+)
    private var idleWarningColor: Color {
        let idle = session.stats.currentIdleDuration
        if idle > 1800 { return DS.stateError.opacity(0.8) }
        if idle > 300 { return DS.stateNeedsInput.opacity(0.8) }
        return DS.textTertiary
    }

    /// Unified status color for left border: orphaned > stuck > agent state > running > inactive
    private var statusColor: Color {
        if session.isOrphaned { return DS.stateOrphaned }
        if session.isAgent && session.stuckInfo != nil {
            return DS.stateError
        }
        if session.isAgent && session.agentState != .inactive {
            return DS.stateColor(for: session.agentState)
        }
        if session.exitedUnexpectedly { return DS.stateError }
        if session.isRunning { return DS.stateWorking.opacity(0.4) }
        return DS.borderSubtle
    }

    private func buildPreview(backend: TerminalBackend) -> String {
        backend.lock()
        let rows = min(backend.rows, maxLines)
        let cols = min(backend.cols, maxCols)
        var lines: [String] = []

        let startRow = max(0, backend.rows - rows)
        for row in startRow..<backend.rows {
            var line = ""
            for col in 0..<cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32 && cp < 0x110000 {
                    line.append(Character(Unicode.Scalar(cp)!))
                } else {
                    line.append(" ")
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        backend.unlock()

        while lines.last?.isEmpty == true { lines.removeLast() }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Auto-selecting TextField

/// NSTextField wrapper that auto-selects all text on appear.
/// Double-click -> text is immediately selected -> type to replace.
struct AutoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        // Become first responder and select all text in one pass
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: AutoSelectTextField

        init(_ parent: AutoSelectTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit()
        }

    }
}
