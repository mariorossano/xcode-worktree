import Foundation
import XCTest
@testable import XcodeWorktreeCore

final class WorktreeScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private let runner = ProcessCommandRunner()

    func testManagedLayoutUsesXcodeWorktreeIdentifiers() {
        XCTAssertEqual(ManagedWorktreeLayout.rootDirectoryName, ".xcode-worktrees")
        XCTAssertEqual(ManagedWorktreeLayout.branchPrefix, "xcode-worktree/")
        XCTAssertTrue(WorktreeHealth.valid.allowsActions)
        XCTAssertTrue(WorktreeHealth.warning.allowsActions)
        XCTAssertFalse(WorktreeHealth.needsAttention.allowsActions)
        XCTAssertEqual(
            WorktreeScanner.defaultRoot.lastPathComponent,
            ManagedWorktreeLayout.rootDirectoryName
        )
    }

    func testTaskLabelRemovesOnlyManagedIdentifier() {
        XCTAssertEqual(WorktreeScanner.taskLabel(from: "mxp-768-012345abcdef"), "mxp-768")
        XCTAssertEqual(WorktreeScanner.taskLabel(from: "mxp-768-not-an-id"), "mxp-768-not-an-id")
        XCTAssertEqual(WorktreeScanner.taskLabel(from: "short"), "short")
    }

    func testPorcelainParserPreservesSpaces() {
        let output = [
            "worktree /tmp/one",
            "HEAD 11111111",
            "branch refs/heads/main",
            "",
            "worktree /tmp/two with spaces",
            "HEAD 22222222",
            "branch refs/heads/feature",
            "",
        ].joined(separator: "\0")

        XCTAssertEqual(
            GitPorcelain.worktreePaths(from: output),
            ["/tmp/one", "/tmp/two with spaces"]
        )
    }

    func testMissingRootIsAnEmptySnapshotNotAnError() throws {
        let container = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: container) }
        let missingRoot = container.appendingPathComponent("not-created-yet", isDirectory: true)

        let snapshot = WorktreeScanner(root: missingRoot).scan()

        XCTAssertNil(snapshot.rootIssue)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: missingRoot.path))
    }

    func testScannerFindsLiveStateAndDerivedData() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        var snapshot = WorktreeScanner(root: fixture.root).scan()
        XCTAssertNil(snapshot.rootIssue)
        XCTAssertTrue(snapshot.warnings.isEmpty)
        XCTAssertEqual(snapshot.items.count, 1)

        var item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.repository, "repo")
        XCTAssertEqual(item.mainWorktreePath, fixture.repository.standardizedFileURL)
        XCTAssertEqual(item.task, "feature-a")
        XCTAssertEqual(item.branch, "xcode-worktree/feature-a-012345abcdef")
        XCTAssertEqual(item.health, .valid)
        XCTAssertFalse(item.isDirty)
        XCTAssertNil(item.derivedDataPath)

        try Data("local change\n".utf8).write(to: fixture.worktree.appendingPathComponent("scratch.txt"))
        let derivedData = fixture.worktree.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 8_192).write(to: derivedData.appendingPathComponent("build.bin"))

        snapshot = WorktreeScanner(root: fixture.root).scan()
        item = try XCTUnwrap(snapshot.items.first)
        XCTAssertTrue(item.isDirty)
        XCTAssertEqual(item.derivedDataPath?.standardizedFileURL, derivedData.standardizedFileURL)

        let size = try DirectorySizer().measure(item)
        XCTAssertGreaterThan(size.totalBytes, 0)
        XCTAssertGreaterThan(size.derivedDataBytes, 0)
        XCTAssertEqual(size.checkoutBytes, size.totalBytes - size.derivedDataBytes)
    }

    func testScannerReportsExternalBranchAsNonBlockingWarning() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        try git(["branch", "-m", "MXP-867-injectedvalues-adoption"], at: fixture.worktree)

        let snapshot = WorktreeScanner(root: fixture.root).scan()
        let item = try XCTUnwrap(snapshot.items.first)

        XCTAssertEqual(item.branch, "MXP-867-injectedvalues-adoption")
        XCTAssertEqual(item.health, .warning)
        XCTAssertTrue(item.health.allowsActions)
        XCTAssertEqual(item.issue, "Branch does not use the managed xcode-worktree prefix.")
    }

    func testScannerRejectsPermissiveRootWithoutChangingIt() throws {
        let container = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        let snapshot = WorktreeScanner(root: root).scan()
        XCTAssertNotNil(snapshot.rootIssue)
        XCTAssertTrue(snapshot.items.isEmpty)

        let attributes = try fileManager.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testScannerDoesNotTreatTrackedDerivedDataAsManagedOutput() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let derivedData = fixture.worktree.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: false)
        try Data("must be preserved\n".utf8).write(to: derivedData.appendingPathComponent("tracked.txt"))
        try git(["add", "-f", "DerivedData/tracked.txt"], at: fixture.worktree)
        try git(["commit", "-m", "Track fixture data"], at: fixture.worktree)

        let snapshot = WorktreeScanner(root: fixture.root).scan()

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertNil(snapshot.items.first?.derivedDataPath)
    }

    func testScannerReportsUnregisteredFolderAsAttention() throws {
        let container = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let candidate = repository.appendingPathComponent("orphan-012345abcdef", isDirectory: true)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repository.path)

        let snapshot = WorktreeScanner(root: root).scan()
        XCTAssertNil(snapshot.rootIssue)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.health, .needsAttention)
        XCTAssertEqual(snapshot.items.first?.task, "orphan")
        XCTAssertNotNil(snapshot.items.first?.issue)
    }

    func testScannerStopsGitValidationAfterATimeoutButKeepsEveryFolderVisible() throws {
        let container = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let first = repository.appendingPathComponent("first-012345abcdef", isDirectory: true)
        let second = repository.appendingPathComponent("second-012345abcdef", isDirectory: true)
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repository.path)
        let timeoutRunner = TimeoutRunner()

        let snapshot = WorktreeScanner(root: root, runner: timeoutRunner).scan()

        XCTAssertEqual(snapshot.items.map(\.task).sorted(), ["first", "second"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.health == .needsAttention })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.issue?.contains("timed out") == true })
        XCTAssertEqual(timeoutRunner.callCount, 2)
    }

    func testScannerRetriesOneTransientTimeout() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let runner = TimeoutOnceRunner()

        let snapshot = WorktreeScanner(root: fixture.root, runner: runner).scan()

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.health, .valid)
        XCTAssertGreaterThan(runner.callCount, 1)
    }

    private func makeFixture() throws -> Fixture {
        let container = try temporaryDirectory()
        let repository = container.appendingPathComponent("source", isDirectory: true)
        let root = container.appendingPathComponent("root", isDirectory: true)
        let repositoryGroup = root.appendingPathComponent("repo", isDirectory: true)
        let worktree = repositoryGroup.appendingPathComponent("feature-a-012345abcdef", isDirectory: true)

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
            "worktree", "add", "--no-track",
            "-b", "xcode-worktree/feature-a-012345abcdef",
            worktree.path, "HEAD",
        ], at: repository)

        return Fixture(container: container, repository: repository, root: root, worktree: worktree)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
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
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("xcode-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let root: URL
        let worktree: URL
    }

    private final class TimeoutRunner: @unchecked Sendable, CommandRunning {
        private let lock = NSLock()
        private var calls = 0

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func run(executable: String, arguments: [String]) throws -> CommandResult {
            lock.lock()
            calls += 1
            lock.unlock()
            throw CommandError.timedOut(executable: executable, seconds: 15)
        }
    }

    private final class TimeoutOnceRunner: @unchecked Sendable, CommandRunning {
        private let lock = NSLock()
        private let runner = ProcessCommandRunner(timeout: 15)
        private var calls = 0

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func run(executable: String, arguments: [String]) throws -> CommandResult {
            lock.lock()
            calls += 1
            let shouldTimeOut = calls == 1
            lock.unlock()

            if shouldTimeOut {
                throw CommandError.timedOut(executable: executable, seconds: 15)
            }
            return try runner.run(executable: executable, arguments: arguments)
        }
    }
}
