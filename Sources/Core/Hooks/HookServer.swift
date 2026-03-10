import Foundation

/// Listens on a Unix domain socket for hook events from CosmodromeHook.
/// Each connection sends a single JSON payload, then disconnects.
public final class HookServer {
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.cosmodrome.hooks", qos: .utility)
    private var socketPath: String?

    /// Called on the hooks queue when an event is received.
    /// Consumer should dispatch to main thread if needed.
    public var onEvent: ((HookEvent) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    /// Start listening on a Unix domain socket.
    /// Returns the socket path for injection into child process env vars.
    @discardableResult
    public func start() -> String {
        let path = NSTemporaryDirectory() + "cosmodrome-\(ProcessInfo.processInfo.processIdentifier).sock"
        start(socketPath: path)
        return path
    }

    /// Start listening on a specific socket path.
    public func start(socketPath path: String) {
        stop()
        socketPath = path

        // Remove stale socket file
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            FileHandle.standardError.write("[HookServer] socket() failed: \(errno)\n".data(using: .utf8)!)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            FileHandle.standardError.write("[HookServer] socket path too long\n".data(using: .utf8)!)
            close(listenFD)
            listenFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFD, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            FileHandle.standardError.write("[HookServer] bind() failed: \(errno)\n".data(using: .utf8)!)
            close(listenFD)
            listenFD = -1
            return
        }

        guard listen(listenFD, 5) == 0 else {
            FileHandle.standardError.write("[HookServer] listen() failed: \(errno)\n".data(using: .utf8)!)
            close(listenFD)
            listenFD = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
                self?.listenFD = -1
            }
        }
        source.resume()
        listenSource = source
    }

    /// Stop listening and clean up the socket file.
    public func stop() {
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let path = socketPath {
            unlink(path)
            socketPath = nil
        }
    }

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Read all data from the client (small payload, single read usually sufficient)
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(clientFD, buf, bufSize)
            if n > 0 {
                data.append(buf, count: n)
            } else {
                break
            }
        }
        close(clientFD)

        guard !data.isEmpty, let event = HookEvent.parse(from: data) else { return }
        onEvent?(event)
    }
}
