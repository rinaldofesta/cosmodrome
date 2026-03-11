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
        VStack(alignment: .leading, spacing: 0) {
            // Row 1: Name + state indicators
            HStack(spacing: Spacing.sm) {
                // State dot (left edge, always visible)
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(isFocused ? 0.5 : 0), radius: 3)

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
            .padding(.horizontal, Spacing.sm)
            .padding(.top, Spacing.sm)
            .padding(.bottom, 3)

            // Row 2: Subtitle — command / agent info / model
            HStack(spacing: Spacing.xs) {
                if session.isAgent {
                    Text(session.agentType?.capitalized ?? "Agent")
                        .font(Typo.caption)
                        .foregroundColor(DS.accent.opacity(0.8))
                    if let model = session.agentModel {
                        Text("·")
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                        Text(model)
                            .font(Typo.caption)
                            .foregroundColor(DS.textTertiary)
                    }
                } else {
                    let cmdName = (session.command as NSString).lastPathComponent
                    Text(cmdName)
                        .font(Typo.caption)
                        .foregroundColor(DS.textTertiary)
                }

                Spacer()

                if session.agentState == .needsInput {
                    Text("needs input")
                        .font(Typo.caption)
                        .foregroundColor(DS.stateNeedsInput)
                        .transition(.opacity)
                } else if session.agentState == .error {
                    Label("error", systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.caption)
                        .foregroundColor(DS.stateError.opacity(0.8))
                        .transition(.opacity)
                } else if session.exitedUnexpectedly {
                    Label("exited", systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.caption)
                        .foregroundColor(DS.stateError.opacity(0.8))
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, 4)

            // Row 3: Detected ports
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
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, 3)
            }

            // Row 4: Agent status info or terminal preview
            if session.isAgent {
                agentStatusRow
            } else if let backend = session.backend {
                let preview = buildPreview(backend: backend)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(DS.textTertiary.opacity(0.7))
                        .lineLimit(maxLines)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.bottom, Spacing.sm)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(attentionBgColor)
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
        .contentShape(Rectangle())
        .animation(Anim.quick, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            startRename()
        }
        .onTapGesture(count: 1) {
            if !isEditing { onSelect() }
        }
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

    /// Agent status row: context, effort, cost, mode — always visible for agent sessions.
    @ViewBuilder
    private var agentStatusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: context + effort + cost
            HStack(spacing: Spacing.xs) {
                HStack(spacing: 2) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 7))
                    Text(session.agentContext ?? "\u{2014}")
                        .font(Typo.captionMono)
                }
                .foregroundColor(session.agentContext != nil ? DS.textSecondary : DS.textTertiary.opacity(0.5))
                if let effort = session.agentEffort {
                    Text(effort)
                        .font(Typo.captionMono)
                        .foregroundColor(DS.textTertiary)
                }
                Spacer()
                if let cost = session.agentCost {
                    Text(cost)
                        .font(Typo.captionMono)
                        .foregroundColor(DS.textTertiary)
                }
            }
            // Line 2: permission mode badge (always visible)
            HStack(spacing: Spacing.xs) {
                let mode = session.agentMode ?? "Default"
                Text(mode)
                    .font(Typo.caption)
                    .foregroundColor(modeColor(mode))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(modeColor(mode).opacity(0.12))
                    .cornerRadius(Radius.sm)
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, Spacing.sm)
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode {
        case "Bypass": return DS.stateError
        case "Accept Edits": return Color(red: 0.9, green: 0.6, blue: 0.2)
        case "Plan": return DS.stateNeedsInput
        case "Auto": return DS.stateWorking
        default: return DS.textSecondary
        }
    }

    /// Whether this session needs attention (needsInput or error).
    private var needsAttention: Bool {
        session.isAgent && (session.agentState == .needsInput || session.agentState == .error)
    }

    private var attentionBgColor: Color {
        if needsAttention {
            return DS.stateColor(for: session.agentState).opacity(0.08)
        }
        return isFocused ? DS.bgSelected : (isHovered ? DS.bgHover : Color.clear)
    }

    private var attentionBorderColor: Color {
        if needsAttention {
            return DS.stateColor(for: session.agentState).opacity(0.5)
        }
        return isFocused ? DS.borderFocus : (isHovered ? DS.borderMedium : DS.borderSubtle)
    }

    private var attentionBorderWidth: CGFloat {
        if needsAttention { return 1.5 }
        return isFocused ? 1.5 : 0.5
    }

    /// Unified status color: agent state > running > inactive
    private var statusColor: Color {
        if session.isAgent && session.agentState != .inactive {
            return DS.stateColor(for: session.agentState)
        }
        if session.exitedUnexpectedly { return DS.stateError }
        if session.isRunning { return DS.stateWorking.opacity(0.6) }
        return DS.stateInactive
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
/// Double-click → text is immediately selected → type to replace.
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
