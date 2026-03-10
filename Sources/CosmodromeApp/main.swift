import AppKit
import Foundation

let version = "1.0.0"

if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print("Cosmodrome \(version)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
