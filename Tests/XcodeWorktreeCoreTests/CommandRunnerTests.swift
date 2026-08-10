import XCTest
@testable import XcodeWorktreeCore

final class CommandRunnerTests: XCTestCase {
    func testGitCryptMissingKeyHasActionableDiagnostic() {
        let error = CommandError.failed(
            executable: "git",
            status: 128,
            message: "git-crypt: Error: Unable to open key file - have you unlocked/initialized this repository yet?\nerror: external filter git-crypt clean failed"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "git-crypt is not unlocked for this worktree. Git cannot safely inspect or commit its protected files; recreate it with the current xcode-worktree skill."
        )
    }

    func testUnrelatedCommandFailureKeepsOriginalDetail() {
        let error = CommandError.failed(
            executable: "git",
            status: 128,
            message: "fatal: bad revision"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "git exited with status 128: fatal: bad revision"
        )
    }

    func testRunnerDrainsLargeStandardOutputAndErrorWithoutDeadlocking() throws {
        let bytesPerStream = 256 * 1_024
        let script = "head -c \(bytesPerStream) /dev/zero; head -c \(bytesPerStream) /dev/zero >&2"

        let result = try ProcessCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", script]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, bytesPerStream)
        XCTAssertEqual(result.standardError.utf8.count, bytesPerStream)
    }

    func testRunnerTerminatesACommandAfterItsTimeout() {
        let runner = ProcessCommandRunner(timeout: 0.1)

        XCTAssertThrowsError(try runner.run(executable: "/bin/sleep", arguments: ["5"])) { error in
            guard case CommandError.timedOut(let executable, _) = error else {
                return XCTFail("Expected a timeout, got \(error)")
            }
            XCTAssertEqual(executable, "/bin/sleep")
        }
    }

    func testRunnerTerminatesChildProcessesAfterItsTimeout() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-runner-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = ProcessCommandRunner(timeout: 0.1)
        let script = "trap '' HUP TERM; (trap '' HUP TERM; sleep 2; touch \"$1\") & wait"

        XCTAssertThrowsError(try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", script, "command-runner-test", marker.path]
        ))

        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "A child process survived after the command timed out"
        )
    }

    func testRunnerHandlesRapidShortCommandsFromADetachedTask() async throws {
        let runner = ProcessCommandRunner(timeout: 1)

        try await Task.detached {
            for _ in 0..<100 {
                let result = try runner.run(executable: "/usr/bin/true", arguments: [])
                XCTAssertEqual(result.terminationStatus, 0)
            }
        }.value
    }
}
