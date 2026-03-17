import Foundation

/// Listens on a Unix domain socket for events from Ghostty shell integration.
/// Similar to HookServer but handles DashboardEvent protocol.
public final class DashboardServer: UnixSocketServer {
    public var onEvent: ((DashboardEvent) -> Void)?
    /// Also handle raw HookEvents (Claude Code lifecycle)
    public var onHookEvent: ((HookEvent) -> Void)?

    public init() {
        super.init(label: "com.cosmodrome.dashboard", qos: .utility)
    }

    /// Start listening. Returns the socket path.
    @discardableResult
    public func start() -> String {
        let path = NSTemporaryDirectory() + "cosmodrome-dashboard-\(ProcessInfo.processInfo.processIdentifier).sock"
        start(socketPath: path)
        return path
    }

    public func start(socketPath path: String) {
        startListening(at: path, backlog: 10)
    }

    override func handleConnection(fd: Int32) {
        let data = readAll(from: fd)
        close(fd)
        guard !data.isEmpty else { return }

        // Try parsing as a DashboardEvent first, then as a HookEvent
        if let event = DashboardEvent.parse(from: data) {
            onEvent?(event)
        } else if let hookEvent = HookEvent.parse(from: data) {
            onHookEvent?(hookEvent)
        }
    }
}
