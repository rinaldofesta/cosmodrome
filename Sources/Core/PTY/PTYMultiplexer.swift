import Foundation
import Darwin

// Typealias to disambiguate kevent struct from kevent() function
private typealias KEvent = Darwin.kevent

/// Multiplexes I/O for all PTY sessions on a single thread using kqueue.
public final class PTYMultiplexer {
    public struct SessionIO {
        public let id: UUID
        public let backend: TerminalBackend
        public let agentDetector: AgentDetector?
        public let onOutput: () -> Void
        public let onExit: () -> Void
        public let onRawOutput: ((UnsafeRawBufferPointer) -> Void)?

        public init(
            id: UUID,
            backend: TerminalBackend,
            agentDetector: AgentDetector?,
            onOutput: @escaping () -> Void,
            onExit: @escaping () -> Void,
            onRawOutput: ((UnsafeRawBufferPointer) -> Void)? = nil
        ) {
            self.id = id
            self.backend = backend
            self.agentDetector = agentDetector
            self.onOutput = onOutput
            self.onExit = onExit
            self.onRawOutput = onRawOutput
        }
    }

    private let kqFD: Int32
    private var thread: Thread?
    private let lock = NSLock()
    private var sessions: [Int32: SessionIO] = [:]
    private let readBuffer: UnsafeMutableRawPointer
    private let readBufferSize = 65536
    private var isRunning = true

    // Pipe for waking up the kqueue thread
    private let wakeReadFD: Int32
    private let wakeWriteFD: Int32

    public init() {
        self.kqFD = kqueue()
        self.readBuffer = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)

        // Create wake pipe
        var pipeFDs: [Int32] = [0, 0]
        pipe(&pipeFDs)
        self.wakeReadFD = pipeFDs[0]
        self.wakeWriteFD = pipeFDs[1]

        // Register wake pipe for reading
        var wakeEvent = KEvent(
            ident: UInt(pipeFDs[0]),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: nil
        )
        kevent(kqFD, &wakeEvent, 1, nil, 0, nil)

        let ioThread = Thread { [weak self] in
            self?.runLoop()
        }
        ioThread.qualityOfService = .userInteractive
        ioThread.name = "com.cosmodrome.io"
        ioThread.start()
        self.thread = ioThread
    }

    deinit {
        isRunning = false
        var byte: UInt8 = 1
        Darwin.write(wakeWriteFD, &byte, 1)
        close(wakeReadFD)
        close(wakeWriteFD)
        close(kqFD)
        readBuffer.deallocate()
    }

    /// Register a new PTY fd for multiplexing.
    public func register(fd: Int32, session: SessionIO) {
        lock.lock()
        sessions[fd] = session
        lock.unlock()

        var event = KEvent(
            ident: UInt(fd),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: nil
        )
        kevent(kqFD, &event, 1, nil, 0, nil)
    }

    /// Unregister a PTY fd.
    public func unregister(fd: Int32) {
        var event = KEvent(
            ident: UInt(fd),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_DELETE),
            fflags: 0, data: 0, udata: nil
        )
        kevent(kqFD, &event, 1, nil, 0, nil)

        lock.lock()
        sessions.removeValue(forKey: fd)
        lock.unlock()
    }

    /// Send data to a PTY fd.
    public func send(to fd: Int32, data: Data) {
        writePTY(fd: fd, data: data)
    }

    /// Number of active sessions.
    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    // MARK: - I/O Loop

    private func runLoop() {
        var events: [KEvent] = .init(repeating: KEvent(), count: 32)

        while isRunning && !Thread.current.isCancelled {
            let n = kevent(kqFD, nil, 0, &events, 32, nil)
            guard n > 0 else {
                if n < 0 && errno == EINTR { continue }
                break
            }

            for i in 0..<Int(n) {
                let fd = Int32(events[i].ident)

                // Check if it's the wake pipe
                if fd == wakeReadFD {
                    var buf: UInt8 = 0
                    _ = Darwin.read(fd, &buf, 1)
                    continue
                }

                lock.lock()
                let session = sessions[fd]
                lock.unlock()

                guard let session else { continue }

                let bytesRead = Darwin.read(fd, readBuffer, readBufferSize)

                if bytesRead <= 0 {
                    if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EINTR) {
                        handleEOF(fd: fd, session: session)
                    }
                    continue
                }

                let slice = UnsafeRawBufferPointer(start: readBuffer, count: bytesRead)

                // Feed to VT parser
                session.backend.process(slice)

                // Raw output hook (for recording)
                session.onRawOutput?(slice)

                // Forward any response data from the terminal back to the PTY
                if let sendData = session.backend.pendingSendData() {
                    writePTY(fd: fd, data: sendData)
                }

                // Agent detection (inline, same thread)
                session.agentDetector?.analyze(lastOutput: slice)

                // Signal main thread to redraw
                session.onOutput()
            }
        }
    }

    private func handleEOF(fd: Int32, session: SessionIO) {
        unregister(fd: fd)
        close(fd)
        DispatchQueue.main.async {
            session.onExit()
        }
    }
}
