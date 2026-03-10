import Foundation

/// Plays back asciicast v2 recordings, delivering events at their recorded timing.
public final class AsciicastPlayer {
    public struct Header {
        public let version: Int
        public let width: Int
        public let height: Int
        public let timestamp: Int?
        public let title: String?
        public let duration: TimeInterval?
    }

    public struct RecordedEvent {
        public let time: TimeInterval
        public let type: String // "o" for output, "i" for input
        public let data: String
    }

    private var events: [RecordedEvent] = []
    private var eventIndex = 0
    private var timer: DispatchSourceTimer?
    private var playbackStart: TimeInterval = 0
    private var speed: Double = 1.0
    private var onEvent: ((RecordedEvent) -> Void)?

    public private(set) var header: Header?
    public private(set) var isPlaying = false

    public init() {}

    /// Load an asciicast v2 file.
    public func load(path: String) throws {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw AsciicastError.emptyFile }

        // Parse header (first line)
        guard let headerData = lines[0].data(using: .utf8),
              let headerObj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let version = headerObj["version"] as? Int,
              let width = headerObj["width"] as? Int,
              let height = headerObj["height"] as? Int else {
            throw AsciicastError.invalidHeader
        }

        self.header = Header(
            version: version,
            width: width,
            height: height,
            timestamp: headerObj["timestamp"] as? Int,
            title: headerObj["title"] as? String,
            duration: headerObj["duration"] as? TimeInterval
        )

        // Parse events (subsequent lines)
        events.removeAll()
        for i in 1..<lines.count {
            guard let data = lines[i].data(using: .utf8),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 3,
                  let time = arr[0] as? Double,
                  let type = arr[1] as? String,
                  let text = arr[2] as? String else {
                continue
            }
            events.append(RecordedEvent(time: time, type: type, data: text))
        }
    }

    /// Start playback, calling the handler for each event at its recorded time.
    public func play(speed: Double = 1.0, onEvent: @escaping (RecordedEvent) -> Void) {
        guard !events.isEmpty else { return }
        self.speed = speed
        self.onEvent = onEvent
        self.eventIndex = 0
        self.isPlaying = true
        self.playbackStart = ProcessInfo.processInfo.systemUptime

        scheduleNext()
    }

    /// Stop playback.
    public func stop() {
        timer?.cancel()
        timer = nil
        isPlaying = false
        onEvent = nil
    }

    /// Reset to beginning.
    public func reset() {
        stop()
        eventIndex = 0
    }

    /// Total duration of the recording.
    public var duration: TimeInterval {
        events.last?.time ?? 0
    }

    /// Number of events.
    public var eventCount: Int { events.count }

    // MARK: - Private

    private func scheduleNext() {
        guard eventIndex < events.count, isPlaying else {
            isPlaying = false
            return
        }

        let event = events[eventIndex]
        let elapsed = ProcessInfo.processInfo.systemUptime - playbackStart
        let targetTime = event.time / speed
        let delay = max(0, targetTime - elapsed)

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            guard let self, self.isPlaying else { return }
            self.onEvent?(event)
            self.eventIndex += 1
            self.scheduleNext()
        }
        source.resume()
        timer = source
    }
}

public enum AsciicastError: Error {
    case emptyFile
    case invalidHeader
}
