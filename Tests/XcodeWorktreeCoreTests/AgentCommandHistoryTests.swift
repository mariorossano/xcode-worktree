import XCTest
@testable import XcodeWorktreeCore

final class AgentCommandHistoryTests: XCTestCase {
    func testRecordingTrimsMovesCommandToFrontAndRemovesDuplicate() {
        let result = AgentCommandHistory.recording(
            "  claude-company  ",
            in: ["codex", "claude-company", "claude-me"]
        )

        XCTAssertEqual(result, ["claude-company", "codex", "claude-me"])
    }

    func testRecordingKeepsOnlyConfiguredNumberOfEntries() {
        let result = AgentCommandHistory.recording(
            "new-agent",
            in: ["one", "two", "three"],
            limit: 3
        )

        XCTAssertEqual(result, ["new-agent", "one", "two"])
    }

    func testRejectsEmptyAndMultilineCommands() {
        XCTAssertNil(AgentCommandHistory.normalizedCommand("   "))
        XCTAssertNil(AgentCommandHistory.normalizedCommand("codex\nrm something"))
        XCTAssertNil(AgentCommandHistory.normalizedCommand("codex\rnext"))
        XCTAssertNil(AgentCommandHistory.normalizedCommand("codex\u{2028}next"))
        XCTAssertNil(AgentCommandHistory.normalizedCommand("codex\u{0085}next"))
    }

    func testEncodedHistoryRoundTripsAndDecodeRemovesDuplicates() {
        let encoded = AgentCommandHistory.encode(["codex", "claude-company", "codex"])

        XCTAssertEqual(encoded, "codex\nclaude-company")
        XCTAssertEqual(AgentCommandHistory.decode(encoded), ["codex", "claude-company"])
    }
}
