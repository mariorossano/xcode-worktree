import Darwin
import Foundation

public struct WorktreeChangePreview: Equatable, Sendable {
    public let stagedPaths: [String]
    public let trackedPathsToStage: [String]
    public let untrackedPathsToAdd: [String]

    public init(
        stagedPaths: [String],
        trackedPathsToStage: [String],
        untrackedPathsToAdd: [String]
    ) {
        self.stagedPaths = stagedPaths
        self.trackedPathsToStage = trackedPathsToStage
        self.untrackedPathsToAdd = untrackedPathsToAdd
    }

    public var allPaths: [String] {
        Array(Set(stagedPaths + trackedPathsToStage + untrackedPathsToAdd))
            .sorted(by: Self.pathOrder)
    }

    public var isEmpty: Bool {
        allPaths.isEmpty
    }

    private static func pathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

public struct WorktreeReleaseResult: Equatable, Sendable {
    public let path: URL
    public let branch: String
    public let commit: String
    public let discardedUncommittedChanges: Bool
    public let discardedDerivedData: Bool

    public init(
        path: URL,
        branch: String,
        commit: String,
        discardedUncommittedChanges: Bool,
        discardedDerivedData: Bool
    ) {
        self.path = path
        self.branch = branch
        self.commit = commit
        self.discardedUncommittedChanges = discardedUncommittedChanges
        self.discardedDerivedData = discardedDerivedData
    }
}

public enum WorktreePreservationError: Error, LocalizedError, Sendable {
    case invalidCommitMessage
    case noCommittableChanges
    case previewChanged
    case stagingFailed(String)
    case stagedFilesChanged
    case commitFailed(String)
    case commitNotCreated
    case worktreeChangedAfterCommit(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommitMessage:
            return "Enter a commit message. The worktree was not removed."
        case .noCommittableChanges:
            return "No tracked or untracked files are available to commit. Ignored files are excluded, and the worktree was not removed."
        case .previewChanged:
            return "The file list changed after it was shown. Review it again before committing; the worktree was not removed."
        case .stagingFailed(let detail):
            return "Git could not stage the displayed files. The worktree was not removed. \(detail)"
        case .stagedFilesChanged:
            return "The staged file list no longer matches the preview. The worktree was not removed; review its current Git state."
        case .commitFailed(let detail):
            return "The commit failed. The worktree was not removed, and files may now be staged. \(detail)"
        case .commitNotCreated:
            return "Git did not create a new commit. The worktree was not removed."
        case .worktreeChangedAfterCommit(let commit):
            return "Commit \(commit) was created, but the worktree changed again before removal. It was not removed."
        }
    }
}

public enum WorktreeReleaseError: Error, LocalizedError, Sendable {
    case refused(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let reason):
            return "Worktree removal was refused: \(reason)"
        case .verificationFailed(let reason):
            return "Worktree removal could not be verified: \(reason)"
        }
    }
}

public struct WorktreeReleaser: Sendable {
    private let root: URL
    private let runner: any CommandRunning
    private let inspectionRunner: any CommandRunning
    private var fileManager: FileManager { .default }

    public init(
        root: URL = WorktreeScanner.defaultRoot,
        runner: any CommandRunning = ProcessCommandRunner(),
        inspectionRunner: any CommandRunning = ProcessCommandRunner(timeout: 15)
    ) {
        self.root = root.standardizedFileURL
        self.runner = runner
        self.inspectionRunner = inspectionRunner
    }

    public func previewChanges(for worktree: ManagedWorktree) throws -> WorktreeChangePreview {
        let validated = try validate(worktree, using: inspectionRunner)
        return try changePreview(at: validated.candidate, using: inspectionRunner)
    }

    public func commitAndRelease(
        _ worktree: ManagedWorktree,
        message: String,
        expectedPreview: WorktreeChangePreview
    ) throws -> WorktreeReleaseResult {
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commitMessage.isEmpty, !commitMessage.contains("\0") else {
            throw WorktreePreservationError.invalidCommitMessage
        }

        let validated = try validate(worktree, using: inspectionRunner)
        let currentPreview = try changePreview(
            at: validated.candidate,
            using: inspectionRunner
        )
        guard currentPreview == expectedPreview else {
            throw WorktreePreservationError.previewChanged
        }
        guard !currentPreview.isEmpty else {
            throw WorktreePreservationError.noCommittableChanges
        }

        let staging = try runGit(["add", "--all", "--", "."], at: validated.candidate)
        guard staging.terminationStatus == 0 else {
            throw WorktreePreservationError.stagingFailed(failureDetail(staging))
        }

        let stagedPreview = try changePreview(
            at: validated.candidate,
            using: inspectionRunner
        )
        guard stagedPreview.trackedPathsToStage.isEmpty,
              stagedPreview.untrackedPathsToAdd.isEmpty,
              Set(stagedPreview.stagedPaths) == Set(currentPreview.allPaths) else {
            throw WorktreePreservationError.stagedFilesChanged
        }

        let commitResult = try runGit(["commit", "-m", commitMessage], at: validated.candidate)
        guard commitResult.terminationStatus == 0 else {
            throw WorktreePreservationError.commitFailed(failureDetail(commitResult))
        }

        let createdCommit = try git(
            ["rev-parse", "HEAD"],
            at: validated.candidate,
            using: inspectionRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard createdCommit != validated.commit else {
            throw WorktreePreservationError.commitNotCreated
        }

        let statusAfterCommit = try git(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            at: validated.candidate,
            using: inspectionRunner
        )
        guard statusAfterCommit.isEmpty else {
            throw WorktreePreservationError.worktreeChangedAfterCommit(String(createdCommit.prefix(8)))
        }

        return try release(worktree)
    }

    public func release(_ worktree: ManagedWorktree) throws -> WorktreeReleaseResult {
        let validated = try validate(worktree, using: inspectionRunner)
        let status = try git(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            at: validated.candidate,
            using: inspectionRunner
        )
        let derivedData = validated.candidate.appendingPathComponent("DerivedData", isDirectory: true)
        let hadDerivedData = isOrdinaryDirectory(derivedData)

        let removal = try runGit(
            ["worktree", "remove", "--force", validated.canonicalCandidate.path],
            at: validated.mainPath
        )
        guard removal.terminationStatus == 0 else {
            throw CommandError.failed(
                executable: "git worktree remove",
                status: removal.terminationStatus,
                message: removal.standardError
            )
        }

        guard !pathEntryExists(validated.candidate) else {
            throw WorktreeReleaseError.verificationFailed("the checkout path still exists")
        }

        let listedAfter = GitPorcelain.worktreePaths(
            from: try git(
                ["worktree", "list", "--porcelain", "-z"],
                at: validated.mainPath,
                using: inspectionRunner
            )
        )
        guard !listedAfter.contains(where: { pathsMatch($0, validated.canonicalCandidate.path) }) else {
            throw WorktreeReleaseError.verificationFailed("Git still registers the removed path")
        }

        let preservedCommit = try git(
            ["rev-parse", "--verify", "refs/heads/\(validated.branch)^{commit}"],
            at: validated.mainPath,
            using: inspectionRunner
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard preservedCommit == validated.commit else {
            throw WorktreeReleaseError.verificationFailed("the preserved branch moved or disappeared")
        }

        return WorktreeReleaseResult(
            path: validated.candidate,
            branch: validated.branch,
            commit: validated.commit,
            discardedUncommittedChanges: !status.isEmpty,
            discardedDerivedData: hadDerivedData
        )
    }

    private func validate(
        _ worktree: ManagedWorktree,
        using commandRunner: any CommandRunning
    ) throws -> ValidatedWorktree {
        let candidate = worktree.path.standardizedFileURL
        let repositoryFolder = candidate.deletingLastPathComponent()

        let canonicalRoot = try validatePrivateDirectory(root, label: "managed root")
        guard repositoryFolder.deletingLastPathComponent().standardizedFileURL.path
                == root.standardizedFileURL.path else {
            throw WorktreeReleaseError.refused("the path is not an exact two-level child of the managed root")
        }
        let canonicalRepository = try validatePrivateDirectory(repositoryFolder, label: "repository folder")
        let canonicalCandidate = try validateOwnedDirectory(candidate, label: "worktree")

        guard canonicalRepository.deletingLastPathComponent().path == canonicalRoot.path,
              canonicalCandidate.deletingLastPathComponent().path == canonicalRepository.path else {
            throw WorktreeReleaseError.refused("the path is not an exact two-level child of the managed root")
        }

        let inside = try git(
            ["rev-parse", "--is-inside-work-tree"],
            at: candidate,
            using: commandRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside == "true" else {
            throw WorktreeReleaseError.refused("Git does not recognize the folder as a worktree")
        }

        let topLevel = try git(
            ["rev-parse", "--show-toplevel"],
            at: candidate,
            using: commandRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathsMatch(topLevel, canonicalCandidate.path) else {
            throw WorktreeReleaseError.refused("Git reports a different worktree root")
        }

        let candidateCommonDirectory = try git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            at: candidate,
            using: commandRunner
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let listedBefore = GitPorcelain.worktreePaths(
            from: try git(
                ["worktree", "list", "--porcelain", "-z"],
                at: candidate,
                using: commandRunner
            )
        )
        guard listedBefore.filter({ pathsMatch($0, canonicalCandidate.path) }).count == 1 else {
            throw WorktreeReleaseError.refused("the exact path is not registered exactly once by Git")
        }
        guard let mainPath = listedBefore.first.map({ URL(fileURLWithPath: $0).standardizedFileURL }),
              !pathsMatch(mainPath.path, canonicalCandidate.path) else {
            throw WorktreeReleaseError.refused("the main worktree cannot be removed")
        }
        if let expectedMain = worktree.mainWorktreePath,
           !pathsMatch(expectedMain.path, mainPath.path) {
            throw WorktreeReleaseError.refused("the repository's main worktree changed since the last scan")
        }

        let mainTopLevel = try git(
            ["rev-parse", "--show-toplevel"],
            at: mainPath,
            using: commandRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathsMatch(mainTopLevel, mainPath.path) else {
            throw WorktreeReleaseError.refused("the repository's main checkout could not be validated")
        }
        let mainCommonDirectory = try git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            at: mainPath,
            using: commandRunner
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathsMatch(candidateCommonDirectory, mainCommonDirectory) else {
            throw WorktreeReleaseError.refused("the worktree belongs to a different Git common directory")
        }

        let branchResult = try runGit(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            at: candidate,
            using: commandRunner
        )
        let branch = branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchResult.terminationStatus == 0, !branch.isEmpty else {
            throw WorktreeReleaseError.refused("the worktree has no branch to preserve")
        }
        guard branch.hasPrefix(ManagedWorktreeLayout.branchPrefix) else {
            throw WorktreeReleaseError.refused("the branch does not use the managed xcode-worktree prefix")
        }

        let commit = try git(
            ["rev-parse", "HEAD"],
            at: candidate,
            using: commandRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branchCommit = try git(
            ["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"],
            at: mainPath,
            using: commandRunner
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchCommit == commit else {
            throw WorktreeReleaseError.refused("the branch no longer points to the worktree's HEAD")
        }

        return ValidatedWorktree(
            candidate: candidate,
            canonicalCandidate: canonicalCandidate,
            mainPath: mainPath,
            branch: branch,
            commit: commit
        )
    }

    private func changePreview(
        at worktree: URL,
        using commandRunner: any CommandRunning
    ) throws -> WorktreeChangePreview {
        let staged = try git(
            ["diff", "--cached", "--name-only", "-z", "--"],
            at: worktree,
            using: commandRunner
        )
        let tracked = try git(
            ["diff", "--name-only", "-z", "--"],
            at: worktree,
            using: commandRunner
        )
        let untracked = try git(
            ["ls-files", "--others", "--exclude-standard", "-z", "--"],
            at: worktree,
            using: commandRunner
        )
        return WorktreeChangePreview(
            stagedPaths: nulPaths(staged),
            trackedPathsToStage: nulPaths(tracked),
            untrackedPathsToAdd: nulPaths(untracked)
        )
    }

    private func nulPaths(_ output: String) -> [String] {
        Array(Set(
            output
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
        )).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func failureDetail(_ result: CommandResult) -> String {
        let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        if !output.isEmpty { return output }
        return "Git exited with status \(result.terminationStatus)."
    }

    private func validatePrivateDirectory(_ url: URL, label: String) throws -> URL {
        let canonical = try validateOwnedDirectory(url, label: label)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0 else {
            throw WorktreeReleaseError.refused("the \(label) is not private to the current user")
        }
        return canonical
    }

    private func validateOwnedDirectory(_ url: URL, label: String) throws -> URL {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw WorktreeReleaseError.refused("the \(label) is not an ordinary directory")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              owner == getuid() else {
            throw WorktreeReleaseError.refused("the \(label) is not owned by the current user")
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isOrdinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) == 0 }
    }

    private func git(
        _ arguments: [String],
        at worktree: URL,
        using commandRunner: any CommandRunning
    ) throws -> String {
        let result = try runGit(arguments, at: worktree, using: commandRunner)
        guard result.terminationStatus == 0 else {
            throw CommandError.failed(
                executable: "git",
                status: result.terminationStatus,
                message: result.standardError
            )
        }
        return result.standardOutput
    }

    private func runGit(_ arguments: [String], at worktree: URL) throws -> CommandResult {
        try runGit(arguments, at: worktree, using: runner)
    }

    private func runGit(
        _ arguments: [String],
        at worktree: URL,
        using commandRunner: any CommandRunning
    ) throws -> CommandResult {
        try commandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", worktree.path] + arguments
        )
    }

    private func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private struct ValidatedWorktree {
    let candidate: URL
    let canonicalCandidate: URL
    let mainPath: URL
    let branch: String
    let commit: String
}
