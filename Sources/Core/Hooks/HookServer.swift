import Foundation

/// Listens on a Unix domain socket for hook events from CosmodromeHook.
/// Each connection sends a single JSON payload, then disconnects.
public final class HookServer: UnixSocketServer {
    /// Called on the hooks queue when an event is received.
    /// Consumer should dispatch to main thread if needed.
    public var onEvent: ((HookEvent) -> Void)?

    public init() {
        super.init(label: "com.cosmodrome.hooks", qos: .utility)
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
        startListening(at: path, backlog: 5)
    }

    override func handleConnection(fd: Int32) {
        let data = readAll(from: fd)
        close(fd)

        guard !data.isEmpty, let event = HookEvent.parse(from: data) else { return }
        onEvent?(event)
    }
}
