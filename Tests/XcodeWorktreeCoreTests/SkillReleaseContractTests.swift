import Foundation
import XCTest
@testable import XcodeWorktreeCore

final class SkillReleaseContractTests: XCTestCase {
    private let fileManager = FileManager.default
    private let runner = ProcessCommandRunner()

    func testSkillRequiresExternalResourceCleanupBeforeWorktreeRemoval() throws {
        let skill = try String(contentsOf: packageRoot.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let releaseSectionStart = try XCTUnwrap(skill.range(of: "## Release a worktree"))
        let releaseSection = String(skill[releaseSectionStart.lowerBound...])

        let barrier = try XCTUnwrap(
            releaseSection.range(of: "While the path still exists, complete and verify all known task cleanup")
        )
        let removal = try XCTUnwrap(
            releaseSection.range(of: "git worktree remove --force")
        )

        XCTAssertLessThan(
            releaseSection.distance(from: releaseSection.startIndex, to: barrier.lowerBound),
            releaseSection.distance(from: releaseSection.startIndex, to: removal.lowerBound)
        )
        XCTAssertTrue(releaseSection.contains("preserve the worktree if required cleanup fails"))
        XCTAssertTrue(releaseSection.contains("Ignore unrelated integrations and ambiguous ownership"))
        XCTAssertTrue(releaseSection.contains("As the last state-changing action"))
        XCTAssertTrue(releaseSection.contains("After removal, perform only read-only verification"))
    }

    func testGenericPathBoundResourceIsReleasedBeforeItsWorktreeDisappears() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let provider = FakePathBoundProvider(
            registry: fixture.container.appendingPathComponent("external-resource.json")
        )

        try provider.claim(id: "resource-123", for: fixture.worktree)
        let stableID = try provider.inspect().id
        try provider.release(from: fixture.worktree)

        XCTAssertEqual(stableID, "resource-123")
        XCTAssertFalse(provider.hasClaim)

        try git(["worktree", "remove", "--force", fixture.worktree.path], at: fixture.repository)

        XCTAssertFalse(fileManager.fileExists(atPath: fixture.worktree.path))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--verify", "refs/heads/\(fixture.branch)^{commit}"], at: fixture.repository),
            fixture.commit
        )
    }

    func testDeletingWorktreeFirstReproducesOrphanedPathBoundResource() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let provider = FakePathBoundProvider(
            registry: fixture.container.appendingPathComponent("external-resource.json")
        )

        try provider.claim(id: "resource-456", for: fixture.worktree)
        try git(["worktree", "remove", "--force", fixture.worktree.path], at: fixture.repository)

        XCTAssertThrowsError(try provider.release(from: fixture.worktree)) { error in
            XCTAssertEqual(error as? FakePathBoundProvider.ProviderError, .worktreeMissing)
        }
        XCTAssertTrue(provider.hasClaim)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeFixture() throws -> Fixture {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("skill-release-contract-tests-\(UUID().uuidString)", isDirectory: true)
        let repository = container.appendingPathComponent("source", isDirectory: true)
        let root = container.appendingPathComponent("root", isDirectory: true)
        let repositoryGroup = root.appendingPathComponent("repo", isDirectory: true)
        let worktree = repositoryGroup.appendingPathComponent("task-012345abcdef", isDirectory: true)
        let branch = "xcode-worktree/task-012345abcdef"

        try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repositoryGroup, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repositoryGroup.path)

        try git(["init"], at: repository)
        try git(["config", "user.name", "Skill Contract Tests"], at: repository)
        try git(["config", "user.email", "skill-contract@example.invalid"], at: repository)
        try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try git(["add", "README.md"], at: repository)
        try git(["commit", "-m", "Initial fixture"], at: repository)
        try git(
            ["worktree", "add", "--no-track", "-b", branch, worktree.path, "HEAD"],
            at: repository
        )

        return Fixture(
            container: container,
            repository: repository,
            worktree: worktree,
            branch: branch,
            commit: try gitOutput(["rev-parse", "HEAD"], at: worktree)
        )
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

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
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
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let worktree: URL
        let branch: String
        let commit: String
    }
}

private struct FakePathBoundProvider {
    enum ProviderError: Error, Equatable {
        case noClaim
        case worktreeMissing
        case wrongWorktree
    }

    struct Record: Codable {
        let id: String
        let worktreePath: String
    }

    let registry: URL

    var hasClaim: Bool {
        FileManager.default.fileExists(atPath: registry.path)
    }

    func claim(id: String, for worktree: URL) throws {
        let record = Record(
            id: id,
            worktreePath: worktree.standardizedFileURL.resolvingSymlinksInPath().path
        )
        try JSONEncoder().encode(record).write(to: registry)
    }

    func inspect() throws -> Record {
        guard let data = FileManager.default.contents(atPath: registry.path) else {
            throw ProviderError.noClaim
        }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    func release(from worktree: URL) throws {
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            throw ProviderError.worktreeMissing
        }
        let record = try inspect()
        guard record.worktreePath == worktree.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw ProviderError.wrongWorktree
        }
        try FileManager.default.removeItem(at: registry)
    }
}
