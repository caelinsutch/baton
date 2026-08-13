import Foundation

/// Reads worktree facts with `git`. The agent may omit them, and a wrong path
/// must never crash a submit, so every call degrades to `nil`.
public enum GitProbe {
    /// Builds a `RepoRef` for a directory. Returns `nil` when the path is not a
    /// git worktree.
    public static func describe(path: String) -> BatonTask.RepoRef? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let top = run(["rev-parse", "--show-toplevel"], in: expanded), !top.isEmpty else {
            return nil
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: expanded)
        let head = run(["rev-parse", "HEAD"], in: expanded)
        let dirty = run(["status", "--porcelain"], in: expanded).map { !$0.isEmpty }
        let commonDir = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: expanded)
        let root = commonDir.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }

        return BatonTask.RepoRef(
            root: root ?? top,
            worktreePath: top,
            branch: branch == "HEAD" ? nil : branch,
            headSha: head,
            isDirty: dirty
        )
    }

    /// Counts the change between two refs. Used for the card headline.
    public static func changeSummary(
        path: String,
        baseRef: String?,
        headRef: String?,
        maxFiles: Int = 40
    ) -> BatonTask.ChangeSummary? {
        let expanded = (path as NSString).expandingTildeInPath
        var arguments = ["diff", "--numstat"]
        if let baseRef, !baseRef.isEmpty {
            arguments.append(headRef.map { "\(baseRef)...\($0)" } ?? baseRef)
        }
        guard let output = run(arguments, in: expanded) else { return nil }

        var files: [String] = []
        var insertions = 0
        var deletions = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            insertions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
            files.append(String(parts[2]))
        }
        guard !files.isEmpty else { return nil }

        return BatonTask.ChangeSummary(
            baseRef: baseRef,
            headRef: headRef,
            filesChanged: files.count,
            insertions: insertions,
            deletions: deletions,
            files: Array(files.prefix(maxFiles))
        )
    }

    /// Runs one git command. Returns trimmed stdout, or `nil` on any failure.
    private static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A missing HOME makes git read the wrong config in some launch contexts.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting so a large diff cannot fill the pipe and deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
