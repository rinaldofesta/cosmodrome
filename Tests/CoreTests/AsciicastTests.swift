import XCTest
@testable import Core

final class AsciicastTests: XCTestCase {

    func testRecorderCreatesValidHeader() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24, title: "Test")
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertFalse(lines.isEmpty, "Should have at least the header line")

        // Parse header
        let headerData = lines[0].data(using: .utf8)!
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertEqual(header["width"] as? Int, 80)
        XCTAssertEqual(header["height"] as? Int, 24)
        XCTAssertEqual(header["title"] as? String, "Test")
        XCTAssertNotNil(header["timestamp"])
    }

    func testRecorderRecordsOutputEvents() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24)
        recorder.record(event: .output, data: "Hello, World!\n".data(using: .utf8)!)
        recorder.record(event: .output, data: "Second line\n".data(using: .utf8)!)
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3) // header + 2 events

        // Parse first event
        let eventData = lines[1].data(using: .utf8)!
        let event = try JSONSerialization.jsonObject(with: eventData) as! [Any]
        XCTAssertEqual(event.count, 3)
        XCTAssertTrue(event[0] is Double)
        XCTAssertEqual(event[1] as? String, "o")
        XCTAssertEqual(event[2] as? String, "Hello, World!\n")
    }

    func testRecorderRecordsInputEvents() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24)
        recorder.record(event: .input, data: "ls\n".data(using: .utf8)!)
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2) // header + 1 event

        let eventData = lines[1].data(using: .utf8)!
        let event = try JSONSerialization.jsonObject(with: eventData) as! [Any]
        XCTAssertEqual(event[1] as? String, "i")
        XCTAssertEqual(event[2] as? String, "ls\n")
    }

    func testRecorderEscapesControlCharacters() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24)
        let textWithControls = "Hello\t\"World\"\n\r\u{1b}[0m"
        recorder.record(event: .output, data: textWithControls.data(using: .utf8)!)
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)

        // The event line should be valid JSON
        let eventData = lines[1].data(using: .utf8)!
        let event = try JSONSerialization.jsonObject(with: eventData) as! [Any]
        let text = event[2] as? String
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("Hello"))
        XCTAssertTrue(text!.contains("World"))
    }

    func testRecorderTimestampsIncrease() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24)
        recorder.record(event: .output, data: "first".data(using: .utf8)!)
        // Small delay to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)
        recorder.record(event: .output, data: "second".data(using: .utf8)!)
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)

        let event1 = try JSONSerialization.jsonObject(with: lines[1].data(using: .utf8)!) as! [Any]
        let event2 = try JSONSerialization.jsonObject(with: lines[2].data(using: .utf8)!) as! [Any]

        let time1 = event1[0] as! Double
        let time2 = event2[0] as! Double
        XCTAssertLessThanOrEqual(time1, time2)
    }

    func testRecordOutputWithUnsafeRawBufferPointer() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-recording-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24)
        let bytes: [UInt8] = Array("test output".utf8)
        bytes.withUnsafeBytes { buffer in
            recorder.recordOutput(buffer)
        }
        recorder.close()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)

        let event = try JSONSerialization.jsonObject(with: lines[1].data(using: .utf8)!) as! [Any]
        XCTAssertEqual(event[2] as? String, "test output")
    }

    func testPlayerLoadsFile() throws {
        let tempDir = NSTemporaryDirectory()
        let path = "\(tempDir)/test-playback-\(UUID().uuidString).cast"
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create a recording
        let recorder = try AsciicastRecorder(path: path, width: 80, height: 24, title: "Playback Test")
        recorder.record(event: .output, data: "hello".data(using: .utf8)!)
        recorder.record(event: .output, data: " world".data(using: .utf8)!)
        recorder.close()

        // Load it
        let player = AsciicastPlayer()
        try player.load(path: path)

        XCTAssertNotNil(player.header)
        XCTAssertEqual(player.header?.version, 2)
        XCTAssertEqual(player.header?.width, 80)
        XCTAssertEqual(player.header?.height, 24)
        XCTAssertEqual(player.header?.title, "Playback Test")
        XCTAssertEqual(player.eventCount, 2)
    }

    func testPlayerInvalidFile() {
        let player = AsciicastPlayer()
        XCTAssertThrowsError(try player.load(path: "/nonexistent/file.cast"))
    }
}
