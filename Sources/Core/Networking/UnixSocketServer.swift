import Foundation

/// Reusable Unix domain socket server base class.
/// Handles socket creation, bind, listen, accept loop, and cleanup.
/// Subclasses override `handleConnection(fd:)` to process each client.
public class UnixSocketServer {
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private(set) public var socketPath: String?
    let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .utility) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    deinit {
        stop()
    }

    /// Start listening on the given path. Returns true on success.
    @discardableResult
    public func startListening(at path: String, backlog: Int32 = 5) -> Bool {
        stop()
        socketPath = path
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            stderrLog("[\(type(of: self))] socket() failed: \(errno)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            stderrLog("[\(type(of: self))] socket path too long")
            closeFD()
            return false
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
            stderrLog("[\(type(of: self))] bind() failed: \(errno)")
            closeFD()
            return false
        }

        guard listen(listenFD, backlog) == 0 else {
            stderrLog("[\(type(of: self))] listen() failed: \(errno)")
            closeFD()
            return false
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let clientFD = accept(self.listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            self.handleConnection(fd: clientFD)
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
                self?.listenFD = -1
            }
        }
        source.resume()
        listenSource = source
        return true
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

    /// Override in subclasses to handle an accepted connection.
    /// The file descriptor must be closed by the implementation.
    func handleConnection(fd: Int32) {
        close(fd)
    }

    /// Read all available data from a client connection.
    func readAll(from fd: Int32, bufSize: Int = 4096) -> Data {
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(fd, buf, bufSize)
            if n > 0 {
                data.append(buf, count: n)
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        return data
    }

    private func closeFD() {
        close(listenFD)
        listenFD = -1
    }
}

/// Write a message to stderr without force-unwrapping.
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
}
