import Foundation

/// Manages git worktree CRUD operations.
///
/// All git process execution runs on a dedicated utility-QoS dispatch queue.
/// UI-facing callers receive results via async/await.
@MainActor
final class WorktreeManager {

    // MARK: - Types

    struct WorktreeInfo: Codable, Equatable, Sendable {
        let path: String
        let branch: String
        let commitHash: String
        let isMain: Bool
    }

    enum WorktreeError: LocalizedError {
        case notAGitRepository(directory: String)
        case gitCommandFailed(command: String, stderr: String)
        case uncommittedChanges(path: String)
        case worktreeNotFound(path: String)
        case branchAlreadyExists(branch: String)
        case parseError(detail: String)

        var errorDescription: String? {
            switch self {
            case .notAGitRepository(let directory):
                return "Not a git repository: \(directory)"
            case .gitCommandFailed(let command, let stderr):
                return "Git command failed: \(command)\n\(stderr)"
            case .uncommittedChanges(let path):
                return "Worktree has uncommitted changes: \(path)"
            case .worktreeNotFound(let path):
                return "Worktree not found: \(path)"
            case .branchAlreadyExists(let branch):
                return "Branch already exists as a worktree: \(branch)"
            case .parseError(let detail):
                return "Failed to parse git output: \(detail)"
            }
        }
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "com.kolt.worktree-manager", qos: .utility)

    // MARK: - Public API

    /// Lists all worktrees for the repository that contains `workingDirectory`.
    func list(workingDirectory: String) async throws -> [WorktreeInfo] {
        let repoRoot = try await gitRepoRoot(workingDirectory: workingDirectory)
        let output = try await runGit(["worktree", "list", "--porcelain"], in: repoRoot)
        return try parseWorktreeList(output, repoRoot: repoRoot)
    }

    /// Creates a new worktree with the given branch.
    /// - Parameters:
    ///   - branch: The branch name to check out in the new worktree.
    ///   - baseBranch: Optional base branch to create from. If nil, uses current HEAD.
    ///   - directory: Optional explicit directory path. If nil, uses convention.
    ///   - workingDirectory: The current working directory of the requesting workspace.
    /// - Returns: Info about the newly created worktree.
    func add(
        branch: String,
        baseBranch: String?,
        directory: String?,
        workingDirectory: String
    ) async throws -> WorktreeInfo {
        let repoRoot = try await gitRepoRoot(workingDirectory: workingDirectory)
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let slug = Self.branchSlug(branch)
        let worktreePath = directory ?? {
            let parentDir = URL(fileURLWithPath: repoRoot).deletingLastPathComponent()
            return parentDir
                .appendingPathComponent("\(repoName)-worktrees")
                .appendingPathComponent(slug)
                .path
        }()

        // Check if branch already exists as a worktree
        let existing = try await list(workingDirectory: workingDirectory)
        if existing.contains(where: { $0.branch == branch }) {
            throw WorktreeError.branchAlreadyExists(branch: branch)
        }

        // Build the git worktree add command.
        // -b creates the branch; appending baseBranch sets the start point.
        var args = ["worktree", "add", "-b", branch, worktreePath]
        if let base = baseBranch {
            args.append(base)
        }

        _ = try await runGit(args, in: repoRoot)

        // Fetch the info for the newly created worktree
        let worktrees = try await list(workingDirectory: workingDirectory)
        guard let info = worktrees.first(where: {
            normalizePath($0.path) == normalizePath(worktreePath)
        }) else {
            throw WorktreeError.parseError(detail: "Created worktree not found in list output")
        }
        return info
    }

    /// Removes a worktree at the given path.
    /// - Parameters:
    ///   - path: The filesystem path of the worktree to remove.
    ///   - force: If true, removes even with uncommitted changes.
    ///   - workingDirectory: The current working directory for git context.
    func remove(path: String, force: Bool, workingDirectory: String) async throws {
        let repoRoot = try await gitRepoRoot(workingDirectory: workingDirectory)

        // Verify worktree exists
        let worktrees = try await list(workingDirectory: workingDirectory)
        guard worktrees.contains(where: { normalizePath($0.path) == normalizePath(path) }) else {
            throw WorktreeError.worktreeNotFound(path: path)
        }

        // Check for uncommitted changes unless force
        if !force {
            let hasChanges = try await hasUncommittedChanges(in: path)
            if hasChanges {
                throw WorktreeError.uncommittedChanges(path: path)
            }
        }

        var args = ["worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append(path)
        _ = try await runGit(args, in: repoRoot)
    }

    // MARK: - Slug Utility

    /// Converts a branch name to a directory-safe slug.
    /// Replaces `/` with `-` and removes other unsafe characters.
    static func branchSlug(_ branch: String) -> String {
        branch
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    // MARK: - Private Helpers

    private func gitRepoRoot(workingDirectory: String) async throws -> String {
        let output = try await runGit(
            ["rev-parse", "--show-toplevel"],
            in: workingDirectory
        )
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw WorktreeError.notAGitRepository(directory: workingDirectory)
        }
        return root
    }

    private func hasUncommittedChanges(in directory: String) async throws -> Bool {
        let output = try await runGit(["status", "--porcelain"], in: directory)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func parseWorktreeList(_ output: String, repoRoot: String) throws -> [WorktreeInfo] {
        // Porcelain format: groups separated by blank lines.
        // Each group has lines like:
        //   worktree /path/to/worktree
        //   HEAD <sha>
        //   branch refs/heads/<name>
        //   (or "detached" instead of "branch")
        let groups = output.components(separatedBy: "\n\n")
        var results: [WorktreeInfo] = []

        for group in groups {
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lines = trimmed.components(separatedBy: "\n")
            var path: String?
            var commitHash: String?
            var branch: String?

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    commitHash = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let fullRef = String(line.dropFirst("branch ".count))
                    // Strip refs/heads/ prefix
                    if fullRef.hasPrefix("refs/heads/") {
                        branch = String(fullRef.dropFirst("refs/heads/".count))
                    } else {
                        branch = fullRef
                    }
                }
            }

            guard let worktreePath = path, let hash = commitHash else {
                continue
            }

            let isMain = normalizePath(worktreePath) == normalizePath(repoRoot)
            results.append(WorktreeInfo(
                path: worktreePath,
                branch: branch ?? "(detached)",
                commitHash: hash,
                isMain: isMain
            ))
        }

        return results
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Runs a git command on the utility queue and returns stdout.
    private func runGit(_ arguments: [String], in directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: WorktreeError.gitCommandFailed(
                        command: "git \(arguments.joined(separator: " "))",
                        stderr: error.localizedDescription
                    ))
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: WorktreeError.gitCommandFailed(
                        command: "git \(arguments.joined(separator: " "))",
                        stderr: stderr
                    ))
                } else {
                    continuation.resume(returning: stdout)
                }
            }
        }
    }
}
