import Foundation
import XCTest
@testable import XcodeWorktreeCore

final class WorktreeReleaserTests: XCTestCase {
    private let fileManager = FileManager.default
    private let runner = ProcessCommandRunner()

    func testPreviewSeparatesStagedTrackedAndUntrackedFilesAndExcludesIgnoredFiles() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        try Data("staged\n".utf8).write(to: fixture.worktree.appendingPathComponent("staged file.txt"))
        try git(["add", "staged file.txt"], at: fixture.worktree)
        try Data("untracked\n".utf8).write(to: fixture.worktree.appendingPathComponent("new file.txt"))
        let derivedData = fixture.worktree.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: false)
        try Data("ignored\n".utf8).write(to: derivedData.appendingPathComponent("build.bin"))

        let preview = try WorktreeReleaser(root: fixture.root).previewChanges(for: fixture.item)

        XCTAssertEqual(preview.stagedPaths, ["staged file.txt"])
        XCTAssertEqual(preview.trackedPathsToStage, ["README.md"])
        XCTAssertEqual(preview.untrackedPathsToAdd, ["new file.txt"])
        XCTAssertEqual(preview.allPaths, ["new file.txt", "README.md", "staged file.txt"])
        XCTAssertFalse(preview.allPaths.contains(where: { $0.hasPrefix("DerivedData/") }))
    }

    func testPreviewBoundsGitValidationWithInspectionTimeout() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }
        let releaser = WorktreeReleaser(
            root: fixture.root,
            inspectionRunner: AlwaysTimeoutRunner()
        )

        XCTAssertThrowsError(try releaser.previewChanges(for: fixture.item)) { error in
            guard case CommandError.timedOut(let executable, let seconds) = error else {
                return XCTFail("Expected a timeout, got \(error)")
            }
            XCTAssertEqual(executable, "/usr/bin/git")
            XCTAssertEqual(seconds, 15)
        }
    }

    func testCommitAndReleaseCommitsDisplayedFilesOnManagedBranchAndExcludesIgnoredFiles() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        try Data("staged\n".utf8).write(to: fixture.worktree.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"], at: fixture.worktree)
        try Data("untracked\n".utf8).write(to: fixture.worktree.appendingPathComponent("scratch.txt"))
        let derivedData = fixture.worktree.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: false)
        try Data("ignored\n".utf8).write(to: derivedData.appendingPathComponent("build.bin"))

        let originalCommit = try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)
        let releaser = WorktreeReleaser(root: fixture.root)
        let preview = try releaser.previewChanges(for: fixture.item)
        let result = try releaser.commitAndRelease(
            fixture.item,
            message: "Preserve worktree changes",
            expectedPreview: preview
        )

        XCTAssertFalse(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertNotEqual(result.commit, originalCommit)
        XCTAssertFalse(result.discardedUncommittedChanges)
        XCTAssertTrue(result.discardedDerivedData)
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--verify", "refs/heads/\(fixture.branch)^{commit}"], at: fixture.repository),
            result.commit
        )
        XCTAssertEqual(
            try gitOutput(["log", "-1", "--format=%s", fixture.branch], at: fixture.repository),
            "Preserve worktree changes"
        )
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: fixture.repository), originalCommit)

        let committedPaths = Set(
            try gitOutput(["ls-tree", "-r", "--name-only", fixture.branch], at: fixture.repository)
                .split(separator: "\n")
                .map(String.init)
        )
        XCTAssertTrue(committedPaths.contains("README.md"))
        XCTAssertTrue(committedPaths.contains("staged.txt"))
        XCTAssertTrue(committedPaths.contains("scratch.txt"))
        XCTAssertFalse(committedPaths.contains(where: { $0.hasPrefix("DerivedData/") }))
    }

    func testCommitAndReleaseRefusesWhenFileListChangedAfterPreview() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        let releaser = WorktreeReleaser(root: fixture.root)
        let preview = try releaser.previewChanges(for: fixture.item)
        let originalCommit = try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)
        try Data("late change\n".utf8).write(to: fixture.worktree.appendingPathComponent("late.txt"))

        XCTAssertThrowsError(try releaser.commitAndRelease(
            fixture.item,
            message: "Should not be created",
            expectedPreview: preview
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("file list changed"))
        }

        XCTAssertTrue(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree), originalCommit)
        XCTAssertTrue(try gitOutput(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            at: fixture.worktree
        ).contains("late.txt"))
    }

    func testCommitFailureKeepsWorktreeAndBranch() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        let hook = fixture.repository
            .appendingPathComponent(".git/hooks/pre-commit", isDirectory: false)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let releaser = WorktreeReleaser(root: fixture.root)
        let preview = try releaser.previewChanges(for: fixture.item)
        let originalCommit = try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)

        XCTAssertThrowsError(try releaser.commitAndRelease(
            fixture.item,
            message: "Blocked by hook",
            expectedPreview: preview
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("commit failed"))
        }

        XCTAssertTrue(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree), originalCommit)
        XCTAssertEqual(
            try gitOutput(["diff", "--cached", "--name-only"], at: fixture.worktree),
            "README.md"
        )
    }

    func testEmptyCommitMessageDoesNotChangeOrRemoveWorktree() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        let releaser = WorktreeReleaser(root: fixture.root)
        let preview = try releaser.previewChanges(for: fixture.item)
        let statusBefore = try gitOutput(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            at: fixture.worktree
        )

        XCTAssertThrowsError(try releaser.commitAndRelease(
            fixture.item,
            message: "   ",
            expectedPreview: preview
        ))

        XCTAssertTrue(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertEqual(
            try gitOutput(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktree),
            statusBefore
        )
    }

    func testReleaseDiscardsLocalContentAndPreservesBranch() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }

        try Data("changed\n".utf8).write(to: fixture.worktree.appendingPathComponent("README.md"))
        try Data("staged\n".utf8).write(to: fixture.worktree.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"], at: fixture.worktree)
        try Data("untracked\n".utf8).write(to: fixture.worktree.appendingPathComponent("scratch.txt"))
        let derivedData = fixture.worktree.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 1_024).write(to: derivedData.appendingPathComponent("build.bin"))

        let expectedCommit = try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)
        let result = try WorktreeReleaser(root: fixture.root).release(fixture.item)

        XCTAssertEqual(result.path.standardizedFileURL, fixture.worktree.standardizedFileURL)
        XCTAssertEqual(result.branch, fixture.branch)
        XCTAssertEqual(result.commit, expectedCommit)
        XCTAssertTrue(result.discardedUncommittedChanges)
        XCTAssertTrue(result.discardedDerivedData)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.worktree.path))

        let registeredPaths = GitPorcelain.worktreePaths(
            from: try gitOutput(["worktree", "list", "--porcelain", "-z"], at: fixture.repository)
        )
        XCTAssertFalse(containsPath(fixture.worktree, in: registeredPaths))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--verify", "refs/heads/\(fixture.branch)^{commit}"], at: fixture.repository),
            expectedCommit
        )
    }

    func testReleaseAllowsExternalBranchAndPreservesIt() throws {
        let branch = "MXP-867-injectedvalues-adoption"
        let fixture = try makeFixture(managed: true, branch: branch)
        defer { try? fileManager.removeItem(at: fixture.container) }
        let expectedCommit = try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)

        let result = try WorktreeReleaser(root: fixture.root).release(fixture.item)

        XCTAssertEqual(result.branch, branch)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"], at: fixture.repository),
            expectedCommit
        )
    }

    func testReleaseRefusesWorktreeOutsideManagedRoot() throws {
        let fixture = try makeFixture(managed: false)
        defer { try? fileManager.removeItem(at: fixture.container) }

        XCTAssertThrowsError(try WorktreeReleaser(root: fixture.root).release(fixture.item))

        XCTAssertTrue(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertTrue(containsPath(
            fixture.worktree,
            in: GitPorcelain.worktreePaths(
                from: try gitOutput(["worktree", "list", "--porcelain", "-z"], at: fixture.repository)
            )
        ))
    }

    func testReleaseUsesOnlyOneForceAndLeavesLockedWorktreeUntouched() throws {
        let fixture = try makeFixture(managed: true)
        defer { try? fileManager.removeItem(at: fixture.container) }
        try git(["worktree", "lock", fixture.worktree.path], at: fixture.repository)

        XCTAssertThrowsError(try WorktreeReleaser(root: fixture.root).release(fixture.item))

        XCTAssertTrue(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertTrue(containsPath(
            fixture.worktree,
            in: GitPorcelain.worktreePaths(
                from: try gitOutput(["worktree", "list", "--porcelain", "-z"], at: fixture.repository)
            )
        ))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--verify", "refs/heads/\(fixture.branch)^{commit}"], at: fixture.repository),
            try gitOutput(["rev-parse", "HEAD"], at: fixture.worktree)
        )
    }

    private func makeFixture(
        managed: Bool,
        branch: String = "xcode-worktree/feature-a-012345abcdef"
    ) throws -> Fixture {
        let container = try temporaryDirectory()
        let repository = container.appendingPathComponent("source", isDirectory: true)
        let root = container.appendingPathComponent("root", isDirectory: true)
        let repositoryGroup = root.appendingPathComponent("repo", isDirectory: true)
        let worktree = managed
            ? repositoryGroup.appendingPathComponent("feature-a-012345abcdef", isDirectory: true)
            : container.appendingPathComponent("outside-worktree", isDirectory: true)

        try fileManager.createDirectory(at: repository, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: repositoryGroup, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repositoryGroup.path)

        try git(["init"], at: repository)
        try git(["config", "user.name", "Xcode Worktree Tests"], at: repository)
        try git(["config", "user.email", "xcode-worktree@example.invalid"], at: repository)
        try Data("DerivedData/\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try git(["add", ".gitignore", "README.md"], at: repository)
        try git(["commit", "-m", "Initial fixture"], at: repository)
        try git([
            "worktree", "add", "--no-track", "-b", branch, worktree.path, "HEAD",
        ], at: repository)

        let item = ManagedWorktree(
            path: worktree,
            mainWorktreePath: repository,
            repository: "repo",
            task: "feature-a",
            branch: branch,
            commit: try gitOutput(["rev-parse", "--short=8", "HEAD"], at: worktree),
            isDirty: false,
            health: branch.hasPrefix(ManagedWorktreeLayout.branchPrefix) ? .valid : .warning,
            issue: branch.hasPrefix(ManagedWorktreeLayout.branchPrefix)
                ? nil
                : "Branch does not use the managed xcode-worktree prefix.",
            derivedDataPath: nil
        )
        return Fixture(
            container: container,
            repository: repository,
            root: root,
            worktree: worktree,
            branch: branch,
            item: item
        )
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        _ = try gitResult(arguments, at: directory)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        try gitResult(arguments, at: directory).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitResult(_ arguments: [String], at directory: URL) throws -> CommandResult {
        let result = try runner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path] + arguments
        )
        guard result.terminationStatus == 0 else {
            throw CommandError.failed(
                executable: "git",
                status: result.terminationStatus,
                message: result.standardError
            )
        }
        return result
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("worktree-releaser-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func containsPath(_ expected: URL, in paths: [String]) -> Bool {
        let canonicalExpected = expected.standardizedFileURL.resolvingSymlinksInPath().path
        return paths.contains {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                == canonicalExpected
        }
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let root: URL
        let worktree: URL
        let branch: String
        let item: ManagedWorktree
    }
}

private struct AlwaysTimeoutRunner: CommandRunning {
    func run(executable: String, arguments: [String]) throws -> CommandResult {
        throw CommandError.timedOut(executable: executable, seconds: 15)
    }
}
