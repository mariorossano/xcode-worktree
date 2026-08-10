import Foundation
import XCTest
@testable import XcodeWorktreeCore

final class WorktreeHistoryTests: XCTestCase {
    func testLoaderParsesRecentCommits() throws {
        let output = [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaa", "Ada", "2026-08-09T10:30:00+02:00", "Add detail", "Explain the detail view.\n",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "bbbbbbbb", "Linus", "2026-08-08T09:15:00+02:00", "Initial commit", "",
        ].joined(separator: "\0") + "\0"
        let loader = WorktreeHistoryLoader(
            runner: StubRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: output,
                standardError: ""
            ))
        )

        let commits = try loader.load(for: worktree())

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].shortHash, "aaaaaaaa")
        XCTAssertEqual(commits[0].subject, "Add detail")
        XCTAssertEqual(commits[0].body, "Explain the detail view.")
        XCTAssertEqual(commits[0].author, "Ada")
        XCTAssertEqual(commits[1].hash, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertTrue(commits[1].body.isEmpty)
    }

    func testLoaderReturnsEmptyHistory() throws {
        let loader = WorktreeHistoryLoader(
            runner: StubRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: "",
                standardError: ""
            ))
        )

        XCTAssertTrue(try loader.load(for: worktree()).isEmpty)
    }

    func testLoaderRejectsMalformedHistory() {
        let loader = WorktreeHistoryLoader(
            runner: StubRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: "hash\0short\0missing-fields\0",
                standardError: ""
            ))
        )

        XCTAssertThrowsError(try loader.load(for: worktree()))
    }

    func testLoaderReportsGitFailure() {
        let loader = WorktreeHistoryLoader(
            runner: StubRunner(result: CommandResult(
                terminationStatus: 128,
                standardOutput: "",
                standardError: "fatal: bad revision"
            ))
        )

        XCTAssertThrowsError(try loader.load(for: worktree())) { error in
            XCTAssertTrue(error.localizedDescription.contains("fatal: bad revision"))
        }
    }

    private func worktree() -> ManagedWorktree {
        ManagedWorktree(
            path: URL(fileURLWithPath: "/tmp/worktree"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            repository: "repo",
            task: "task",
            branch: "xcode-worktree/task-012345abcdef",
            commit: "aaaaaaaa",
            isDirty: false,
            health: .valid,
            issue: nil,
            derivedDataPath: nil
        )
    }

    private struct StubRunner: CommandRunning {
        let result: CommandResult

        func run(executable: String, arguments: [String]) throws -> CommandResult {
            result
        }
    }
}
