import Foundation

/// Records terminal session output in asciicast v2 format.
/// See: https://docs.asciinema.org/manual/asciicast/v2/
public final class AsciicastRecorder {
    public enum Event: String {
        case output = "o"
        case input = "i"
    }

    private let fileHandle: FileHandle
    private let startTime: TimeInterval
    private let lock = NSLock()
    private var closed = false

    /// Create a recorder that writes to the given file path.
    /// Writes the asciicast v2 header immediately.
    public init(path: String, width: Int, height: Int, title: String? = nil, shell: String? = nil) throws {
        let url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
        self.startTime = ProcessInfo.processInfo.systemUptime

        // Write header
        var header: [String: Any] = [
            "version": 2,
            "width": width,
            "height": height,
            "timestamp": Int(Date().timeIntervalSince1970),
        ]
        if let title { header["title"] = title }
        var env: [String: String] = ["TERM": "xterm-256color"]
        if let shell { env["SHELL"] = shell }
        header["env"] = env

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        fileHandle.write(headerData)
        fileHandle.write(Data([0x0A])) // newline
    }

    /// Record an event (output or input) with the given data.
    public func record(event: Event, data: Data) {
        guard !closed else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        // asciicast v2 event: [time, type, data]
        // We manually build JSON to avoid escaping issues with control characters
        let escapedText = jsonEscape(text)
        let line = "[\(String(format: "%.6f", elapsed)), \"\(event.rawValue)\", \"\(escapedText)\"]\n"

        lock.lock()
        defer { lock.unlock() }
        if let lineData = line.data(using: .utf8) {
            fileHandle.write(lineData)
        }
    }

    /// Record raw bytes as output.
    public func recordOutput(_ bytes: UnsafeRawBufferPointer) {
        guard !closed, bytes.count > 0 else { return }
        let data = Data(bytes: bytes.baseAddress!, count: bytes.count)
        record(event: .output, data: data)
    }

    /// Record raw bytes as input.
    public func recordInput(_ data: Data) {
        guard !closed else { return }
        record(event: .input, data: data)
    }

    /// Finish recording and close the file.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        fileHandle.closeFile()
    }

    deinit {
        close()
    }

    // MARK: - JSON Escaping

    private func jsonEscape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result += String(scalar)
                }
            }
        }
        return result
    }
}
