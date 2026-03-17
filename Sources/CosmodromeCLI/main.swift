import Foundation

// MARK: - CLI for controlling a running Cosmodrome instance via Unix socket.
//
// Usage:
//   cosmodrome-cli status
//   cosmodrome-cli list-projects
//   cosmodrome-cli list-sessions [--project <id>]
//   cosmodrome-cli focus <session-id>
//   cosmodrome-cli content <session-id> [--lines <n>]

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let command = args[1]

if command == "--help" || command == "-h" {
    printUsage()
    exit(0)
}

// Build the control request
var requestArgs: [String: String] = [:]

switch command {
case "status", "list-projects", "fleet-stats":
    break

case "activity":
    if let idx = args.firstIndex(of: "--since"), idx + 1 < args.count {
        requestArgs["since_minutes"] = args[idx + 1]
    }
    if let idx = args.firstIndex(of: "--session"), idx + 1 < args.count {
        requestArgs["session_id"] = args[idx + 1]
    }
    if let idx = args.firstIndex(of: "--category"), idx + 1 < args.count {
        requestArgs["category"] = args[idx + 1]
    }

case "list-sessions":
    if let idx = args.firstIndex(of: "--project"), idx + 1 < args.count {
        requestArgs["project_id"] = args[idx + 1]
    }

case "focus":
    guard args.count >= 3 else {
        printError("Usage: cosmodrome-cli focus <session-id>")
        exit(1)
    }
    requestArgs["session_id"] = args[2]

case "content":
    guard args.count >= 3 else {
        printError("Usage: cosmodrome-cli content <session-id> [--lines <n>]")
        exit(1)
    }
    requestArgs["session_id"] = args[2]
    if let idx = args.firstIndex(of: "--lines"), idx + 1 < args.count {
        requestArgs["lines"] = args[idx + 1]
    }

default:
    printError("Unknown command: \(command)")
    printUsage()
    exit(1)
}

let request: [String: Any] = [
    "command": command,
    "args": requestArgs,
]

// Connect to the control socket
let socketPath = controlSocketPath()
let response = sendRequest(request, to: socketPath)

if let response {
    if let ok = response["ok"] as? Bool, ok {
        if let data = response["data"] as? String {
            // Try pretty-printing JSON
            if let jsonData = data.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: pretty, encoding: .utf8) {
                print(prettyStr)
            } else {
                print(data)
            }
        } else {
            print("OK")
        }
    } else {
        let error = response["error"] as? String ?? "Unknown error"
        printError(error)
        exit(1)
    }
} else {
    printError("Failed to connect to Cosmodrome. Is it running?")
    exit(1)
}

// MARK: - Helpers

func controlSocketPath() -> String {
    let tmpDir = NSTemporaryDirectory()
    let uid = getuid()
    return "\(tmpDir)cosmodrome-\(uid).control.sock"
}

func sendRequest(_ request: [String: Any], to socketPath: String) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst, src.baseAddress!, src.count)
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return nil }

    // Send request as JSON + newline
    guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    data.append(0x0A)
    data.withUnsafeBytes { buf in
        guard let ptr = buf.baseAddress else { return }
        _ = Darwin.write(fd, ptr, buf.count)
    }

    // Shutdown write side to signal end of request
    shutdown(fd, SHUT_WR)

    // Read response
    var responseData = Data()
    let bufSize = 65536
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }

    while true {
        let n = read(fd, buf, bufSize)
        if n > 0 {
            responseData.append(buf, count: n)
        } else {
            break
        }
    }

    guard !responseData.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
}

func printUsage() {
    let usage = """
    cosmodrome-cli — Control a running Cosmodrome instance

    USAGE:
      cosmodrome-cli <command> [options]

    COMMANDS:
      status                        Show overview of running Cosmodrome
      list-projects                 List all projects
      list-sessions [--project ID]  List sessions (default: active project)
      focus <session-id>            Focus a specific session
      content <session-id>          Get terminal content
        --lines N                     Last N lines only
      fleet-stats                   Show fleet-wide agent statistics
      activity [options]            Show activity log (agent events timeline)
        --since N                     Last N minutes only (default: all)
        --session ID                  Filter to specific session
        --category CAT                Filter: files, commands, errors, tasks, subagents
    """
    print(usage)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}
