import XCTest
@testable import Core

final class PTYProcessTests: XCTestCase {

    /// Wait for data to be available on a non-blocking fd using poll().
    private func waitForData(fd: Int32, timeoutMs: Int32 = 2000) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ret = poll(&pfd, 1, timeoutMs)
        return ret > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    func testSpawnEcho() throws {
        let result = try spawnPTY(
            command: "/bin/echo",
            arguments: ["hello"],
            cwd: "/tmp",
            size: (cols: 80, rows: 24)
        )

        XCTAssertTrue(result.fd >= 0)
        XCTAssertTrue(result.pid > 0)

        // Wait for data (fd is non-blocking)
        guard waitForData(fd: result.fd) else {
            close(result.fd)
            var status: Int32 = 0
            waitpid(result.pid, &status, 0)
            XCTFail("Timed out waiting for PTY output")
            return
        }

        // Read output
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = read(result.fd, &buffer, 1024)
        XCTAssertTrue(bytesRead > 0, "Expected positive bytesRead, got \(bytesRead)")

        let output = String(bytes: buffer[0..<max(0, bytesRead)], encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("hello"), "Expected 'hello' in output, got: \(output)")

        close(result.fd)

        // Wait for child
        var status: Int32 = 0
        waitpid(result.pid, &status, 0)
    }

    func testSpawnWithBackend() throws {
        let result = try spawnPTY(
            command: "/bin/echo",
            arguments: ["test output"],
            cwd: "/tmp",
            size: (cols: 80, rows: 24)
        )

        let backend = SwiftTermBackend(cols: 80, rows: 24)

        // Wait for data (fd is non-blocking)
        guard waitForData(fd: result.fd) else {
            close(result.fd)
            var status: Int32 = 0
            waitpid(result.pid, &status, 0)
            XCTFail("Timed out waiting for PTY output")
            return
        }

        // Read and feed to backend
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(result.fd, &buffer, 4096)
        XCTAssertTrue(bytesRead > 0)

        buffer.withUnsafeBytes { rawBuffer in
            let slice = UnsafeRawBufferPointer(
                start: rawBuffer.baseAddress,
                count: bytesRead
            )
            backend.process(slice)
        }

        // Check that backend has content
        let cell = backend.cell(row: 0, col: 0)
        XCTAssertNotEqual(cell.codepoint, 0, "Expected non-zero codepoint after processing output")

        close(result.fd)
        var status: Int32 = 0
        waitpid(result.pid, &status, 0)
    }

    func testResize() throws {
        let result = try spawnPTY(
            command: "/bin/sh",
            arguments: ["-c", "sleep 0.1"],
            cwd: "/tmp",
            size: (cols: 80, rows: 24)
        )

        // Should not crash
        resizePTY(fd: result.fd, cols: 120, rows: 40)

        close(result.fd)
        var status: Int32 = 0
        waitpid(result.pid, &status, 0)
    }
}
