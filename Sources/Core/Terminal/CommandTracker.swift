import Foundation

/// Tracks shell command lifecycle using OSC 133 semantic prompt markers.
/// Shells that support this protocol emit escape sequences:
///   OSC 133;A — prompt shown (ready for input)
///   OSC 133;B — command started executing
///   OSC 133;C — command output starts
///   OSC 133;D;exitcode — command finished with exit code
public final class CommandTracker {
    /// Current command execution state.
    public struct CommandState {
        public var command: String?
        public var startedAt: Date?
        public var isExecuting: Bool = false
        public var isPromptVisible: Bool = false
    }

    public private(set) var state = CommandState()

    /// Called when a command completes. Parameters: command (if captured), exit code, duration.
    public var onCommandCompleted: ((String?, Int?, TimeInterval) -> Void)?

    public init() {}

    /// Handle an OSC 133 sequence. Called from the terminal backend's OSC handler.
    /// The `params` string is everything after "133;" in the OSC payload.
    public func handleOsc133(_ params: String) {
        guard let marker = params.first else { return }

        switch marker {
        case "A":
            // Prompt start — shell is ready for input
            state.isPromptVisible = true
            state.isExecuting = false

        case "B":
            // Command start — user hit enter, command is executing
            state.isPromptVisible = false
            state.isExecuting = true
            state.startedAt = Date()
            // Command text is sometimes passed as a parameter after B
            let rest = String(params.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            state.command = rest.isEmpty ? nil : rest

        case "C":
            // Command output start — similar to B but marks where output begins
            if !state.isExecuting {
                state.isExecuting = true
                state.startedAt = state.startedAt ?? Date()
            }

        case "D":
            // Command finished — parse exit code
            let exitCode: Int?
            let rest = String(params.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            if !rest.isEmpty {
                exitCode = Int(rest)
            } else {
                exitCode = nil
            }

            let duration: TimeInterval
            if let start = state.startedAt {
                duration = Date().timeIntervalSince(start)
            } else {
                duration = 0
            }

            let command = state.command
            onCommandCompleted?(command, exitCode, duration)

            // Reset for next command
            state.command = nil
            state.startedAt = nil
            state.isExecuting = false

        default:
            break
        }
    }
}
