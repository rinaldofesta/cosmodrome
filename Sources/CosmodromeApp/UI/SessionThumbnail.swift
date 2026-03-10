import AppKit
import Core
import SwiftUI

/// Generates a low-resolution text-based preview of a terminal session's content.
/// Uses the backend's cell data to create a simple text representation.
struct SessionThumbnailView: View {
    let session: Session
    let isFocused: Bool
    let sessionIndex: Int
    var onSelect: () -> Void = {}
    var onRestart: () -> Void = {}
    let maxLines: Int = 6
    let maxCols: Int = 40

    @State private var isEditing = false
    @State private var editName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header
            HStack(spacing: 4) {
                Text("\(sessionIndex)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 14)

                if session.isAgent {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                }

                if isEditing {
                    TextField("Session name", text: $editName, onCommit: {
                        commitRename()
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .focused($isNameFocused)
                    .onExitCommand { isEditing = false }
                    .onAppear { isNameFocused = true }
                } else {
                    Text(session.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }

                Spacer()
                if session.isRunning {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundColor(.green.opacity(0.6))
                } else if session.exitedUnexpectedly {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.red.opacity(0.8))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

            // Terminal preview
            if let backend = session.backend {
                let preview = buildPreview(backend: backend)
                Text(preview)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(maxLines)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            } else if session.exitedUnexpectedly {
                Text("Exited — click to restart")
                    .font(.system(size: 8))
                    .foregroundColor(.red.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            } else {
                Text("Not running")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
        .background(isFocused ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .contentShape(Rectangle())
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

    private var stateColor: Color {
        switch session.agentState {
        case .working: return .green
        case .needsInput: return .yellow
        case .error: return .red
        case .inactive: return .gray
        }
    }

    private func buildPreview(backend: TerminalBackend) -> String {
        backend.lock()
        let rows = min(backend.rows, maxLines)
        let cols = min(backend.cols, maxCols)
        var lines: [String] = []

        // Show the last N rows (most recent content)
        let startRow = max(0, backend.rows - rows)
        for row in startRow..<backend.rows {
            var line = ""
            for col in 0..<cols {
                let cell = backend.cell(row: row, col: col)
                let cp = cell.codepoint
                if cp >= 32 && cp < 0x10000 {
                    line.append(Character(Unicode.Scalar(cp)!))
                } else {
                    line.append(" ")
                }
            }
            // Trim trailing spaces
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        backend.unlock()

        // Trim trailing empty lines
        while lines.last?.isEmpty == true { lines.removeLast() }

        return lines.joined(separator: "\n")
    }
}
