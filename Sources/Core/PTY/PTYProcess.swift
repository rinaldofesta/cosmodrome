import Foundation
import Darwin

public enum PTYError: Error {
    case forkFailed(errno: Int32)
    case invalidCommand(String)
}

public struct PTYSpawnResult: Sendable {
    public let fd: Int32
    public let pid: pid_t
}

/// Spawn a child process in a new PTY. Returns the master fd and child pid.
public func spawnPTY(
    command: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    cwd: String,
    size: (cols: UInt16, rows: UInt16)
) throws -> PTYSpawnResult {
    var winSize = winsize(
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: 0,
        ws_ypixel: 0
    )
    var masterFD: Int32 = 0
    let pid = forkpty(&masterFD, nil, nil, &winSize)

    guard pid >= 0 else {
        throw PTYError.forkFailed(errno: errno)
    }

    if pid == 0 {
        // Child process
        var env = ProcessInfo.processInfo.environment

        // Strip ALL Claude Code env vars so each session is a fresh instance
        for key in env.keys where key.hasPrefix("CLAUDE") {
            env.removeValue(forKey: key)
        }

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Cosmodrome"
        env["TERM_PROGRAM_VERSION"] = "0.2.0"
        // Ensure proper UTF-8 locale for Unicode rendering
        if env["LANG"] == nil && env["LC_ALL"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        env.merge(environment) { _, new in new }

        for (k, v) in env {
            setenv(k, v, 1)
        }

        if chdir(cwd) != 0 {
            // If chdir fails, try home directory
            if let home = env["HOME"] {
                chdir(home)
            }
        }

        // Make shells login shells by prefixing argv[0] with '-'
        // This matches Terminal.app/iTerm2 behavior and ensures
        // profile files (~/.zprofile, ~/.bash_profile) are loaded.
        let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "dash"]
        let basename = (command as NSString).lastPathComponent
        let argv0 = shellNames.contains(basename) ? "-\(basename)" : command

        let allArgs = [argv0] + arguments
        let cArgs = allArgs.map { strdup($0) } + [nil]
        execvp(command, cArgs)
        _exit(127)
    }

    // Set non-blocking on master fd
    let flags = fcntl(masterFD, F_GETFL)
    if flags >= 0 {
        fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
    }

    return PTYSpawnResult(fd: masterFD, pid: pid)
}

/// Resize the PTY window.
public func resizePTY(fd: Int32, cols: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
    var winSize = winsize(
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: pixelWidth,
        ws_ypixel: pixelHeight
    )
    _ = ioctl(fd, TIOCSWINSZ, &winSize)
}

/// Write data to the PTY master fd.
public func writePTY(fd: Int32, data: Data) {
    data.withUnsafeBytes { buffer in
        guard let ptr = buffer.baseAddress else { return }
        var remaining = buffer.count
        var offset = 0
        while remaining > 0 {
            let written = write(fd, ptr.advanced(by: offset), remaining)
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
            offset += written
            remaining -= written
        }
    }
}
