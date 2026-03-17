import Foundation

/// Unix socket server for CLI control of the running Cosmodrome app.
/// Accepts JSON request-response pairs over individual connections.
public final class ControlServer: UnixSocketServer {
    /// Handler for incoming commands. Called on the control queue.
    /// Must return a ControlResponse synchronously.
    public var onCommand: ((ControlRequest) -> ControlResponse)?

    public init() {
        super.init(label: "com.cosmodrome.control", qos: .userInitiated)
    }

    /// Start listening. Returns the socket path.
    @discardableResult
    public func start() -> String {
        let path = controlSocketPath()
        start(at: path)
        return path
    }

    /// Start listening on a specific path.
    public func start(at path: String) {
        startListening(at: path, backlog: 5)
    }

    /// Standard socket path for this user.
    public static func defaultSocketPath() -> String {
        controlSocketPath()
    }

    override func handleConnection(fd: Int32) {
        // Read request (newline-delimited)
        var data = Data()
        let bufSize = 8192
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(fd, buf, bufSize)
            if n > 0 {
                data.append(buf, count: n)
                if data.last == 0x0A { break }
            } else {
                break
            }
        }

        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
            response = onCommand?(request) ?? .failure("No handler registered")
        } else {
            response = .failure("Invalid JSON request")
        }

        // Send response
        if let responseData = try? JSONEncoder().encode(response) {
            var toSend = responseData
            toSend.append(0x0A)
            toSend.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress else { return }
                _ = Darwin.write(fd, ptr, buf.count)
            }
        }

        close(fd)
    }
}

/// Standard control socket path.
private func controlSocketPath() -> String {
    let tmpDir = NSTemporaryDirectory()
    let uid = getuid()
    return "\(tmpDir)cosmodrome-\(uid).control.sock"
}
