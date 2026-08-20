import Darwin
import Foundation

public struct WorktreeScanner: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(ManagedWorktreeLayout.rootDirectoryName, isDirectory: true)
    }

    private let root: URL
    private let runner: any CommandRunning
    private var fileManager: FileManager { .default }

    public init(
        root: URL = WorktreeScanner.defaultRoot,
        runner: any CommandRunning = ProcessCommandRunner(timeout: 15)
    ) {
        self.root = root.standardizedFileURL
        self.runner = runner
    }

    public func scan() -> WorktreeSnapshot {
        guard fileManager.fileExists(atPath: root.path) else {
            return WorktreeSnapshot(root: root, items: [])
        }

        if let issue = privateDirectoryIssue(at: root, label: "Managed root") {
            return WorktreeSnapshot(root: root, items: [], rootIssue: issue)
        }

        var items: [ManagedWorktree] = []
        var warnings: [ScanWarning] = []
        var gitValidationUnavailable: String?

        do {
            for repositoryURL in try safeChildDirectories(of: root) {
                if let issue = privateDirectoryIssue(at: repositoryURL, label: "Repository folder") {
                    warnings.append(ScanWarning(path: repositoryURL, message: issue))
                    continue
                }

                for candidateURL in try safeChildDirectories(of: repositoryURL) {
                    let repository = repositoryURL.lastPathComponent
                    if let gitValidationUnavailable {
                        items.append(attention(
                            candidateURL,
                            repository: repository,
                            task: Self.taskLabel(from: candidateURL.lastPathComponent),
                            issue: gitValidationUnavailable,
                            inspectDerivedData: false
                        ))
                        continue
                    }

                    do {
                        items.append(try inspectRetryingOneTimeout(
                            candidateURL,
                            repository: repository
                        ))
                    } catch CommandError.timedOut {
                        let issue = "Git validation timed out twice. Refresh again; if it persists, verify access to the repository."
                        gitValidationUnavailable = issue
                        items.append(attention(
                            candidateURL,
                            repository: repository,
                            task: Self.taskLabel(from: candidateURL.lastPathComponent),
                            issue: issue,
                            inspectDerivedData: false
                        ))
                    } catch {
                        items.append(attention(
                            candidateURL,
                            repository: repository,
                            task: Self.taskLabel(from: candidateURL.lastPathComponent),
                            issue: "Git validation failed: \(error.localizedDescription)",
                            inspectDerivedData: false
                        ))
                    }
                }
            }
        } catch {
            return WorktreeSnapshot(
                root: root,
                items: items,
                warnings: warnings,
                rootIssue: "The managed root could not be read: \(error.localizedDescription)"
            )
        }

        items.sort {
            if $0.health != $1.health {
                return healthSortOrder($0.health) < healthSortOrder($1.health)
            }
            if $0.repository != $1.repository { return $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
            return $0.task.localizedStandardCompare($1.task) == .orderedAscending
        }
        warnings.sort { $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending }

        return WorktreeSnapshot(root: root, items: items, warnings: warnings)
    }

    private func inspectRetryingOneTimeout(
        _ candidate: URL,
        repository: String
    ) throws -> ManagedWorktree {
        do {
            return try inspect(candidate, repository: repository)
        } catch CommandError.timedOut {
            return try inspect(candidate, repository: repository)
        }
    }

    private func safeChildDirectories(of parent: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return try fileManager
            .contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private func privateDirectoryIssue(at url: URL, label: String) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return "\(label) is not an ordinary directory."
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return "\(label) permissions could not be verified."
        }

        guard owner == getuid() else {
            return "\(label) is not owned by the current user."
        }
        guard permissions & 0o077 == 0 else {
            return "\(label) grants permissions to group or other users."
        }
        return nil
    }

    private func inspect(_ candidate: URL, repository: String) throws -> ManagedWorktree {
        let task = Self.taskLabel(from: candidate.lastPathComponent)

        let inside = try git(["rev-parse", "--is-inside-work-tree"], at: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside == "true" else {
            return attention(candidate, repository: repository, task: task, issue: "Git does not recognize this folder as a worktree.")
        }

        let topLevel = try git(["rev-parse", "--show-toplevel"], at: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathsMatch(topLevel, candidate.path) else {
            return attention(candidate, repository: repository, task: task, issue: "Git reports a different worktree root.")
        }

        _ = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: candidate)
        let list = try git(["worktree", "list", "--porcelain", "-z"], at: candidate)
        let worktreePaths = GitPorcelain.worktreePaths(from: list)
        let registered = worktreePaths
            .contains { pathsMatch($0, candidate.path) }
        guard registered else {
            return attention(candidate, repository: repository, task: task, issue: "The exact path is not registered by Git.")
        }

        let branchResult = try runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: candidate)
        let branch = branchResult.terminationStatus == 0
            ? branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let commit = try git(["rev-parse", "--short=8", "HEAD"], at: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try git(["status", "--porcelain=v1", "--untracked-files=normal"], at: candidate)
        let isDirty = !status.isEmpty

        let health: WorktreeHealth
        let issue: String?
        if branch == nil {
            health = .needsAttention
            issue = "Detached HEAD; managed release requires a branch to preserve."
        } else if branch?.hasPrefix(ManagedWorktreeLayout.branchPrefix) == false {
            health = .warning
            issue = "Branch does not use the managed xcode-worktree prefix."
        } else {
            health = .valid
            issue = nil
        }

        let derivedData = safeDerivedData(at: candidate)
        return ManagedWorktree(
            path: candidate,
            mainWorktreePath: worktreePaths.first.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            },
            repository: repository,
            task: task,
            branch: branch,
            commit: commit,
            isDirty: isDirty,
            health: health,
            issue: issue,
            derivedDataPath: derivedData
        )
    }

    private func healthSortOrder(_ health: WorktreeHealth) -> Int {
        switch health {
        case .valid: 0
        case .warning: 1
        case .needsAttention: 2
        }
    }

    private func attention(
        _ path: URL,
        repository: String,
        task: String,
        issue: String,
        inspectDerivedData: Bool = true
    ) -> ManagedWorktree {
        ManagedWorktree(
            path: path,
            mainWorktreePath: nil,
            repository: repository,
            task: task,
            branch: nil,
            commit: nil,
            isDirty: false,
            health: .needsAttention,
            issue: issue,
            derivedDataPath: inspectDerivedData ? safeDerivedData(at: path) : nil
        )
    }

    private func safeDerivedData(at worktree: URL) -> URL? {
        let candidate = worktree.appendingPathComponent("DerivedData", isDirectory: true)
        guard fileManager.fileExists(atPath: candidate.path),
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }

        guard let tracked = try? git(["ls-files", "--", "DerivedData"], at: worktree),
              tracked.isEmpty else {
            return nil
        }

        guard let ignored = try? runGit(
            ["check-ignore", "--no-index", candidate.path + "/"],
            at: worktree
        ), ignored.terminationStatus == 0 else {
            return nil
        }

        return candidate
    }

    private func git(_ arguments: [String], at worktree: URL) throws -> String {
        let result = try runGit(arguments, at: worktree)
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
        try runner.run(executable: "/usr/bin/git", arguments: ["-C", worktree.path] + arguments)
    }

    private func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func taskLabel(from leafName: String) -> String {
        guard leafName.count > 13 else { return leafName }
        let suffixStart = leafName.index(leafName.endIndex, offsetBy: -12)
        let separator = leafName.index(before: suffixStart)
        let suffix = leafName[suffixStart...]
        guard leafName[separator] == "-",
              suffix.allSatisfy({ $0.isHexDigit }) else {
            return leafName
        }
        return String(leafName[..<separator])
    }
}

enum GitPorcelain {
    static func worktreePaths(from output: String) -> [String] {
        output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .compactMap { field -> String? in
                let prefix = "worktree "
                guard field.hasPrefix(prefix) else { return nil }
                return String(field.dropFirst(prefix.count))
            }
    }
}
