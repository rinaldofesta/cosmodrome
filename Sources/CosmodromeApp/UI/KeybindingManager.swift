import AppKit

final class KeybindingManager {
    struct Binding: Hashable {
        let key: UInt16
        let modifiers: NSEvent.ModifierFlags

        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(modifiers.rawValue)
        }

        static func == (lhs: Binding, rhs: Binding) -> Bool {
            lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
        }
    }

    enum Action {
        case projectByIndex(Int)
        case projectNext, projectPrevious
        case sessionNext, sessionPrevious
        case toggleFocus
        case toggleActivityLog
        case newSession, closeSession, newProject
        case jumpNextNeedsInput
        case commandPalette
        case enterNormalMode
    }

    enum Mode {
        case normal
        case command
    }

    private(set) var mode: Mode = .normal

    /// Called when the mode changes.
    var onModeChanged: ((Mode) -> Void)?

    // Normal mode: bindings that require modifier keys (Cmd, Ctrl, etc.)
    private var normalBindings: [Binding: Action] = [:]
    // Command mode: single-letter bindings for navigation
    private var commandBindings: [Binding: Action] = [:]

    init() {
        setupNormalBindings()
        setupCommandBindings()
    }

    private func setupNormalBindings() {
        // Cmd+1-9: switch project
        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, keyCode) in digitKeyCodes.enumerated() {
            normalBindings[Binding(key: keyCode, modifiers: .command)] = .projectByIndex(i + 1)
        }

        // Cmd+Shift+Up/Down: cycle sessions
        normalBindings[Binding(key: 126, modifiers: [.command, .shift])] = .sessionPrevious  // Up
        normalBindings[Binding(key: 125, modifiers: [.command, .shift])] = .sessionNext       // Down

        // Cmd+Enter: toggle focus
        normalBindings[Binding(key: 36, modifiers: .command)] = .toggleFocus

        // Cmd+T: new session
        normalBindings[Binding(key: 17, modifiers: .command)] = .newSession

        // Cmd+W: close session
        normalBindings[Binding(key: 13, modifiers: .command)] = .closeSession

        // Cmd+Shift+T: new project
        normalBindings[Binding(key: 17, modifiers: [.command, .shift])] = .newProject

        // Cmd+Shift+N: jump to next agent needing input
        normalBindings[Binding(key: 45, modifiers: [.command, .shift])] = .jumpNextNeedsInput

        // Cmd+P: command palette
        normalBindings[Binding(key: 35, modifiers: .command)] = .commandPalette

        // Cmd+L: toggle activity log
        normalBindings[Binding(key: 37, modifiers: .command)] = .toggleActivityLog

        // Cmd+]: next project, Cmd+[: previous project
        normalBindings[Binding(key: 30, modifiers: .command)] = .projectNext
        normalBindings[Binding(key: 33, modifiers: .command)] = .projectPrevious

        // Cmd+Shift+]: next session, Cmd+Shift+[: previous session
        normalBindings[Binding(key: 30, modifiers: [.command, .shift])] = .sessionNext
        normalBindings[Binding(key: 33, modifiers: [.command, .shift])] = .sessionPrevious

        // Ctrl+Space: toggle to command mode (keyCode 49 = Space)
        normalBindings[Binding(key: 49, modifiers: .control)] = .commandPalette // initially opens palette; toggleMode handled in MainWindowController
    }

    private func setupCommandBindings() {
        // Single-key bindings (no modifiers) for command mode
        // Key codes for US keyboard layout
        commandBindings[Binding(key: 38, modifiers: [])] = .sessionNext       // j
        commandBindings[Binding(key: 40, modifiers: [])] = .sessionPrevious   // k
        commandBindings[Binding(key: 4, modifiers: [])] = .projectPrevious    // h
        commandBindings[Binding(key: 37, modifiers: [])] = .projectNext       // l
        commandBindings[Binding(key: 45, modifiers: [])] = .newSession        // n
        commandBindings[Binding(key: 7, modifiers: [])] = .closeSession       // x
        commandBindings[Binding(key: 35, modifiers: [])] = .commandPalette    // p
        commandBindings[Binding(key: 3, modifiers: [])] = .toggleFocus        // f
        commandBindings[Binding(key: 44, modifiers: [])] = .commandPalette    // /
        commandBindings[Binding(key: 53, modifiers: [])] = .enterNormalMode   // Escape

        // Also keep Ctrl+Space in command mode to toggle back
        commandBindings[Binding(key: 49, modifiers: .control)] = .enterNormalMode
    }

    func toggleMode() {
        mode = (mode == .normal) ? .command : .normal
        onModeChanged?(mode)
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        onModeChanged?(mode)
    }

    /// Returns the action if a keybinding matches, nil otherwise.
    func match(event: NSEvent) -> Action? {
        let meaningful: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        let flags = event.modifierFlags.intersection(meaningful)
        let binding = Binding(key: event.keyCode, modifiers: flags)

        switch mode {
        case .normal:
            return normalBindings[binding]
        case .command:
            // In command mode, check command bindings first, then fall through to normal
            if let action = commandBindings[binding] {
                return action
            }
            // Still allow Cmd+ shortcuts in command mode
            if flags.contains(.command) {
                return normalBindings[binding]
            }
            // Any other key in command mode: return nil (don't forward to PTY)
            return nil
        }
    }

    /// Whether the current mode should suppress key forwarding to PTY.
    var suppressesPTYInput: Bool {
        mode == .command
    }
}
