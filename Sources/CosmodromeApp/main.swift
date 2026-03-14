import AppKit
import Foundation

let version = "0.2.0"

if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print("Cosmodrome \(version)")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    Cosmodrome \(version) — Terminal dashboard for AI agents

    Usage:
      CosmodromeApp               Launch full terminal emulator
      CosmodromeApp --dashboard   Launch Ghostty dashboard mode
      CosmodromeApp --mcp         Enable MCP server (JSON-RPC over stdio)

    Dashboard mode monitors your Ghostty sessions, groups them by project,
    shows agent status, and lets you switch between them with one click.

    Setup: source Scripts/cosmodrome-shell-integration.zsh in your .zshrc
    """)
    exit(0)
}

let isDashboardMode = CommandLine.arguments.contains("--dashboard")

let app = NSApplication.shared
let delegate = AppDelegate(dashboardMode: isDashboardMode)
app.delegate = delegate
app.run()
