import Foundation

/// Manages git worktrees for isolating agent sessions.
public struct GitWorktree {
    /// Info about a single worktree.
    public struct WorktreeInfo: Sendable {
        public let path: String
        public let branch: String
        public let isMain: Bool
    }

    /// Check if a directory is inside a git repository.
    public static func isGitRepo(at path: String) -> Bool {
        runGit(["rev-parse", "--is-inside-work-tree"], in: path) != nil
    }

    /// List all worktrees in the repo containing the given path.
    public static func list(in path: String) -> [WorktreeInfo] {
        guard let output = runGit(["worktree", "list", "--porcelain"], in: path) else {
            return []
        }

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isMain = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("worktree ") {
                // Save previous entry
                if let p = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: p,
                        branch: currentBranch ?? "detached",
                        isMain: isMain
                    ))
                }
                currentPath = String(l.dropFirst("worktree ".count))
                currentBranch = nil
                isMain = false
            } else if l.hasPrefix("branch ") {
                let ref = String(l.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if l == "bare" || l == "" {
                // End of entry
            }
        }

        // Save last entry
        if let p = currentPath {
            worktrees.append(WorktreeInfo(
                path: p,
                branch: currentBranch ?? "detached",
                isMain: worktrees.isEmpty // first worktree is main
            ))
        }
        if let first = worktrees.first {
            worktrees[0] = WorktreeInfo(path: first.path, branch: first.branch, isMain: true)
        }

        return worktrees
    }

    /// Create a new worktree with a new branch.
    public static func create(in repoPath: String, branch: String, path: String) -> Bool {
        runGit(["worktree", "add", "-b", branch, path], in: repoPath) != nil
    }

    /// Create a worktree from an existing branch.
    public static func checkout(in repoPath: String, branch: String, path: String) -> Bool {
        runGit(["worktree", "add", path, branch], in: repoPath) != nil
    }

    /// Remove a worktree.
    public static func remove(path: String) -> Bool {
        // Find the repo root from any worktree
        guard let repoRoot = runGit(["rev-parse", "--git-common-dir"], in: path) else {
            return false
        }
        let commonDir = repoRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentDir = (commonDir as NSString).deletingLastPathComponent
        return runGit(["worktree", "remove", path, "--force"], in: parentDir) != nil
    }

    /// Get current branch name.
    public static func currentBranch(in path: String) -> String? {
        guard let output = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: path) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get short status (modified/staged/untracked counts).
    public static func shortStatus(in path: String) -> (modified: Int, staged: Int, untracked: Int)? {
        guard let output = runGit(["status", "--porcelain"], in: path) else {
            return nil
        }
        var modified = 0, staged = 0, untracked = 0
        for line in output.split(separator: "\n") {
            guard line.count >= 2 else { continue }
            let index = line.index(line.startIndex, offsetBy: 0)
            let work = line.index(line.startIndex, offsetBy: 1)
            if line[index] == "?" { untracked += 1 }
            else {
                if line[index] != " " { staged += 1 }
                if line[work] != " " { modified += 1 }
            }
        }
        return (modified: modified, staged: staged, untracked: untracked)
    }

    // MARK: - Private

    private static func runGit(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
