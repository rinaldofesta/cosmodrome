import Foundation
import CoreGraphics

public final class LayoutEngine {
    public enum Mode: String, Sendable {
        case grid
        case focus
    }

    public struct LayoutEntry {
        public let sessionId: UUID
        public let frame: CGRect
    }

    public var mode: Mode = .grid
    public var focusedSessionId: UUID?

    public init() {}

    /// Calculate viewport for each visible session.
    public func layout(sessionIds: [UUID], in bounds: CGRect) -> [LayoutEntry] {
        guard !sessionIds.isEmpty else { return [] }

        switch mode {
        case .grid:
            return gridLayout(sessionIds: sessionIds, in: bounds)
        case .focus:
            return focusLayout(sessionIds: sessionIds, in: bounds)
        }
    }

    private func gridLayout(sessionIds: [UUID], in bounds: CGRect) -> [LayoutEntry] {
        let (cols, rows) = autoGrid(count: sessionIds.count)
        let cellW = bounds.width / CGFloat(cols)
        let cellH = bounds.height / CGFloat(rows)

        return sessionIds.enumerated().map { (i, id) in
            let col = i % cols
            let row = i / cols
            let frame = CGRect(
                x: bounds.origin.x + CGFloat(col) * cellW,
                y: bounds.origin.y + bounds.height - CGFloat(row + 1) * cellH,
                width: cellW,
                height: cellH
            )
            return LayoutEntry(sessionId: id, frame: frame)
        }
    }

    private func focusLayout(sessionIds: [UUID], in bounds: CGRect) -> [LayoutEntry] {
        guard let focusedId = focusedSessionId,
              sessionIds.contains(focusedId) else {
            // Fallback to grid if focused session not found
            return gridLayout(sessionIds: sessionIds, in: bounds)
        }
        return [LayoutEntry(sessionId: focusedId, frame: bounds)]
    }

    /// Calculate optimal grid dimensions for a given session count.
    public func autoGrid(count: Int) -> (cols: Int, rows: Int) {
        switch count {
        case 0: return (1, 1)
        case 1: return (1, 1)
        case 2: return (2, 1)
        case 3...4: return (2, 2)
        case 5...6: return (3, 2)
        case 7...9: return (3, 3)
        default: return (4, Int(ceil(Double(count) / 4.0)))
        }
    }

    /// Find which session contains a given point.
    public func sessionAt(point: CGPoint, entries: [LayoutEntry]) -> UUID? {
        for entry in entries {
            if entry.frame.contains(point) {
                return entry.sessionId
            }
        }
        return nil
    }

    /// Toggle between grid and focus mode.
    public func toggleFocus(sessionId: UUID) {
        if mode == .focus && focusedSessionId == sessionId {
            mode = .grid
            focusedSessionId = nil
        } else {
            mode = .focus
            focusedSessionId = sessionId
        }
    }
}
