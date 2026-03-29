import Foundation
import Combine
import Bonsplit

/// Represents a file changed in the git working directory.
struct ChangedFile: Equatable, Sendable {
    let path: String
    let status: String
    let insertions: Int
    let deletions: Int
}

/// FSEvents-based watcher for git working directory changes.
/// Monitors `.git/index` for staging area changes and runs `git diff` to detect modifications.
final class GitWatcher: ObservableObject {

    /// Files that have changed relative to the git index.
    @Published private(set) var changedFiles: [ChangedFile] = []

    /// Raw unified diff output for the currently selected file.
    @Published private(set) var currentDiff: String = ""

    /// The current git branch name, if available.
    @Published private(set) var branchName: String?

    /// The working directory containing the `.git` folder.
    private let workingDirectory: String

    /// Background queue for all git process execution.
    private let gitQueue = DispatchQueue(label: "com.kolt.git-watcher", qos: .utility)

    /// Debounce interval for coalescing rapid file system events.
    private static let debounceInterval: TimeInterval = 0.2

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var isClosed: Bool = false

    // MARK: - Init

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        startWatching()
        refreshAsync()
    }

    // MARK: - Public API

    /// Select a specific file to view its diff.
    func selectFile(_ path: String) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            let diff = self.runGitDiff(forFile: path)
            DispatchQueue.main.async {
                self.currentDiff = diff
            }
        }
    }

    /// Force a full refresh of changed files and branch name.
    func refresh() {
        refreshAsync()
    }

    /// Stop watching and clean up resources.
    func stop() {
        isClosed = true
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        stopFileWatcher()
    }

    // MARK: - Git Actions

    /// Stage a file: `git add <path>`
    func stageFile(_ path: String, completion: @escaping (Bool) -> Void) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runGitCommand(["add", "--", path])
            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()
            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
                completion(true)
            }
        }
    }

    /// Unstage a file: `git reset HEAD <path>`
    func unstageFile(_ path: String, completion: @escaping (Bool) -> Void) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runGitCommand(["reset", "HEAD", "--", path])
            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()
            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
                completion(true)
            }
        }
    }

    /// Revert a file: `git checkout -- <path>`
    func revertFile(_ path: String, completion: @escaping (Bool) -> Void) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runGitCommand(["checkout", "--", path])
            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()
            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
                completion(true)
            }
        }
    }

    /// Stage all files: `git add -A`
    func stageAll(completion: @escaping (Bool) -> Void) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runGitCommand(["add", "-A"])
            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()
            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
                completion(true)
            }
        }
    }

    /// Revert all files: `git checkout -- .`
    func revertAll(completion: @escaping (Bool) -> Void) {
        gitQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runGitCommand(["checkout", "--", "."])
            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()
            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
                completion(true)
            }
        }
    }

    // MARK: - File Watching

    private func startWatching() {
        let gitIndexPath = (workingDirectory as NSString).appendingPathComponent(".git/index")

        let fd = open(gitIndexPath, O_EVTONLY)
        guard fd >= 0 else {
            #if DEBUG
            dlog("[GitWatcher] Failed to open .git/index at \(gitIndexPath)")
            #endif
            return
        }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: gitQueue
        )

        source.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    // Retry reattach after a short delay (atomic git operations).
                    self.gitQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, !self.isClosed else { return }
                        DispatchQueue.main.async {
                            self.startWatching()
                            self.refreshAsync()
                        }
                    }
                }
            } else {
                self.scheduleDebouncedRefresh()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshAsync()
        }
        debounceWorkItem = workItem
        gitQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    // MARK: - Git Operations

    private func refreshAsync() {
        gitQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            let files = self.runGitDiffNameStatus()
            let branch = self.runGitBranchName()

            DispatchQueue.main.async {
                self.changedFiles = files
                self.branchName = branch
            }
        }
    }

    /// Runs `git diff --name-status` and `git diff --numstat` to gather changed file info.
    private func runGitDiffNameStatus() -> [ChangedFile] {
        let nameStatusOutput = runGitCommand(["diff", "--name-status"])
        let numStatOutput = runGitCommand(["diff", "--numstat"])

        // Parse numstat for insertions/deletions per file.
        var statsByPath: [String: (insertions: Int, deletions: Int)] = [:]
        for line in numStatOutput.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            let insertions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let path = String(parts[2])
            statsByPath[path] = (insertions, deletions)
        }

        // Parse name-status and combine with numstat data.
        var files: [ChangedFile] = []
        for line in nameStatusOutput.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { continue }
            let status = String(parts[0])
            let path = String(parts[1])
            let stats = statsByPath[path] ?? (insertions: 0, deletions: 0)
            files.append(ChangedFile(
                path: path,
                status: status,
                insertions: stats.insertions,
                deletions: stats.deletions
            ))
        }
        return files
    }

    /// Runs `git diff <file>` for a specific file and returns the unified diff output.
    private func runGitDiff(forFile path: String) -> String {
        runGitCommand(["diff", "--", path])
    }

    /// Runs `git rev-parse --abbrev-ref HEAD` to get the current branch name.
    private func runGitBranchName() -> String? {
        let output = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// Executes a git command in the working directory and returns stdout as a string.
    private func runGitCommand(_ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            #if DEBUG
            dlog("[GitWatcher] git command failed: \(arguments.joined(separator: " ")) error=\(error)")
            #endif
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    deinit {
        debounceWorkItem?.cancel()
        fileWatchSource?.cancel()
    }
}
