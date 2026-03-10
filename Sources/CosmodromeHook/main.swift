import Foundation

/// CosmodromeHook — tiny binary invoked by Claude Code's hooks system.
/// Reads JSON event data from stdin and forwards it to Cosmodrome
/// via a Unix domain socket specified in COSMODROME_HOOK_SOCKET.

guard let socketPath = ProcessInfo.processInfo.environment["COSMODROME_HOOK_SOCKET"] else {
    // No socket configured — silently exit (don't break Claude Code)
    exit(0)
}

// Read all of stdin
let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty else { exit(0) }

// Inject session ID from env if present
var payload: [String: Any]?
if let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
    var mutable = json
    if let sessionId = ProcessInfo.processInfo.environment["COSMODROME_SESSION_ID"] {
        mutable["session_id"] = sessionId
    }
    payload = mutable
}

let dataToSend: Data
if let payload, let enriched = try? JSONSerialization.data(withJSONObject: payload) {
    dataToSend = enriched
} else {
    dataToSend = input
}

// Connect to Unix socket and send
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
            _ = memcpy(dst, src.baseAddress!, src.count)
        }
    }
}

let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { addrPtr in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(fd, sockaddrPtr, addrLen)
    }
}

guard connected == 0 else {
    close(fd)
    exit(0)
}

dataToSend.withUnsafeBytes { buffer in
    guard let ptr = buffer.baseAddress else { return }
    var remaining = buffer.count
    var offset = 0
    while remaining > 0 {
        let written = write(fd, ptr.advanced(by: offset), remaining)
        if written < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            break
        }
        offset += written
        remaining -= written
    }
}

close(fd)
exit(0)
