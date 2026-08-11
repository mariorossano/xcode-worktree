import Foundation
import XCTest

final class SkillBuildIsolationContractTests: XCTestCase {
    func testSkillRetriggersBeforeLaterXcodeInterfaceActionsInSelectedWorktree() throws {
        let skill = try skillText()
        let frontmatterEnd = try XCTUnwrap(skill.range(of: "\n---", range: skill.index(after: skill.startIndex)..<skill.endIndex))
        let frontmatter = String(skill[..<frontmatterEnd.upperBound])

        XCTAssertTrue(frontmatter.contains("before any Xcode interface invocation that may load, inspect, discover, list, resolve, build, test, or run"))
        XCTAssertTrue(frontmatter.contains("selected earlier in the current session"))
    }

    func testSelectedWorktreeRemainsBoundAcrossLaterSubtasksAndInterfaces() throws {
        let skill = try skillText()
        let binding = try normalizedWhitespace(section(
            named: "## Keep the selected worktree bound to the session",
            endingAt: "## Keep managed branches attached and stable",
            in: skill
        ))

        XCTAssertTrue(binding.contains("across prompts, subtasks, verification requests, compaction"))
        XCTAssertTrue(binding.contains("tool or build-interface changes"))
        XCTAssertTrue(binding.contains("Creating, resuming, or explicitly selecting a managed worktree makes its exact path active"))
        XCTAssertTrue(binding.contains("Shell, editor, and integration defaults never change the active path"))
        XCTAssertTrue(binding.contains("Verified exact-ref reuse also makes the matched worktree active"))
        XCTAssertTrue(binding.contains("Releasing a worktree clears the active path only when the released worktree is the active one"))
        XCTAssertTrue(binding.contains("Do not guess a replacement from shell or build-interface defaults"))
        XCTAssertTrue(binding.contains("Before every Xcode project action"))
    }

    func testLaterRefRequestCanReuseOnlyAnExactSessionRecordedWorktree() throws {
        let binding = try normalizedWhitespace(section(
            named: "## Keep the selected worktree bound to the session",
            endingAt: "## Keep managed branches attached and stable",
            in: try skillText()
        ))

        XCTAssertTrue(binding.contains("every managed worktree this session creates, resumes, or explicitly selects"))
        XCTAssertTrue(binding.contains("exactly one candidate passes fresh checks"))
        XCTAssertTrue(binding.contains("registered at the exact path in the same Git common directory"))
        XCTAssertTrue(binding.contains("`git symbolic-ref --short HEAD` confirms an attached branch"))
        XCTAssertTrue(binding.contains("`HEAD` equals the resolved target commit"))
        XCTAssertTrue(binding.contains("`git status --porcelain=v1 --untracked-files=all` is empty"))
        XCTAssertTrue(binding.contains("no other known agent is using it"))
        XCTAssertTrue(binding.contains("no active build is using it"))
        XCTAssertTrue(binding.contains("A matching worktree merely discovered on disk is not eligible"))
        XCTAssertTrue(binding.contains("never infer session history or ownership"))
        XCTAssertTrue(binding.contains("more than one eligible recorded candidate passes these checks"))
    }

    func testLaterRefRequestsKeepManagedBranchesAttachedAndStable() throws {
        let refChange = try normalizedWhitespace(section(
            named: "## Keep managed branches attached and stable",
            endingAt: "## Use the managed root",
            in: try skillText()
        ))

        XCTAssertTrue(refChange.contains("Keep `HEAD` attached to the branch registered for each managed worktree"))
        XCTAssertTrue(refChange.contains("Never detach `HEAD`"))
        XCTAssertTrue(refChange.contains("Keep using the active worktree if its `HEAD` already equals that commit"))
        XCTAssertTrue(refChange.contains("select one exact recorded candidate only through the checks above"))
        XCTAssertTrue(refChange.contains("stop with every existing worktree unchanged"))
        XCTAssertTrue(refChange.contains("Do not merge, rebase, checkout, reset, detach, or move an existing managed branch"))
    }

    func testUnmatchedRefRequiresFreshWorktreeApprovalWithoutRetargeting() throws {
        let refChange = try normalizedWhitespace(section(
            named: "## Keep managed branches attached and stable",
            endingAt: "## Use the managed root",
            in: try skillText()
        ))

        XCTAssertTrue(refChange.contains("ask whether the user wants a fresh managed worktree for the target"))
        XCTAssertTrue(refChange.contains("A request merely to build, test, or run another ref is not approval"))
        XCTAssertTrue(refChange.contains("a worktree request or approval from earlier in the same session"))
        XCTAssertTrue(refChange.contains("Wait for an affirmative response specific to this new creation"))
        XCTAssertTrue(refChange.contains("Do not merge, rebase, checkout, reset, detach, or move"))
        XCTAssertTrue(refChange.contains("without the user's explicit approval"))
        XCTAssertFalse(refChange.contains("git merge --ff-only"))
        XCTAssertFalse(refChange.contains("git merge-base --is-ancestor"))
    }

    func testBuildIsolationContractIsIndependentOfBuildInterface() throws {
        let skill = try skillText()
        let scope = try normalizedWhitespace(section(
            named: "## Scope",
            endingAt: "## Interpret the request",
            in: skill
        ))
        let isolation = try normalizedWhitespace(section(
            named: "## Keep Xcode build context and DerivedData inside the worktree",
            endingAt: "## Inspect and measure",
            in: skill
        ))

        XCTAssertTrue(scope.contains("an **Xcode project action** is any agent-controlled interface invocation"))
        XCTAssertTrue(scope.contains("load, inspect, discover, list, resolve, build, test, or run"))
        XCTAssertTrue(isolation.contains("Apply this section to every Xcode project action"))
        XCTAssertTrue(isolation.contains("Before the first Xcode project action after selecting a worktree"))
        XCTAssertTrue(isolation.contains("not to any particular build interface"))
        XCTAssertTrue(isolation.contains("checkout, project, or workspace input"))
        XCTAssertTrue(isolation.contains("Configure both the input context and effective DerivedData path"))
        XCTAssertTrue(isolation.contains("wrapper, plugin, MCP, editor, or other integration"))
        XCTAssertTrue(isolation.contains("stop before building"))
        XCTAssertTrue(isolation.contains("first Xcode project action introduced by each later prompt or subtask"))
        XCTAssertTrue(isolation.contains("may reuse verified, unchanged checkout and DerivedData configuration"))
        XCTAssertTrue(isolation.contains("never replaces an operation-specific external-resource ownership or lease check"))
        XCTAssertTrue(isolation.contains("restore every task-mutated temporary interface setting"))
        XCTAssertTrue(isolation.contains("invocation-scoped configuration that leaves no state behind requires no restoration"))
        XCTAssertFalse(isolation.contains("before release when available"))
    }

    func testReadOnlyDiscoveryCannotBypassOutputIsolation() throws {
        let skill = try normalizedWhitespace(section(
            named: "## Keep Xcode build context and DerivedData inside the worktree",
            endingAt: "## Inspect and measure",
            in: try skillText()
        ))

        XCTAssertTrue(skill.contains("Discovery, listing, settings inspection, and dependency resolution"))
        XCTAssertTrue(skill.contains("initialize caches even when an interface presents them as read-only"))
        XCTAssertTrue(skill.contains("Apply the same output-path requirement to those operations"))
        XCTAssertTrue(skill.contains("do not invoke it with an external default"))
        XCTAssertTrue(skill.contains("**Hard stop for raw `xcodebuild` discovery:**"))
        XCTAssertTrue(skill.contains("never run `xcodebuild -list`, `xcodebuild -showBuildSettings`, or `xcodebuild -resolvePackageDependencies`"))
        XCTAssertTrue(skill.contains("that exact invocation includes a verified worktree-local `-derivedDataPath`"))
        XCTAssertTrue(skill.contains("inspect repository metadata with non-Xcode tools or stop"))
    }

    func testGitCryptVerificationNeverReadsProtectedContents() throws {
        let creation = try normalizedWhitespace(section(
            named: "## Create a worktree",
            endingAt: "## Enter and leave in each agent",
            in: try skillText()
        ))

        XCTAssertTrue(creation.contains("**Protected-content hard stop:**"))
        XCTAssertTrue(creation.contains("never read or parse a protected path to verify decryption"))
        XCTAssertTrue(creation.contains("Do not use `cat`, `head`, `tail`, `strings`, `file`, `plutil`"))
        XCTAssertTrue(creation.contains("another content-reading command for that check"))
        XCTAssertTrue(creation.contains("file metadata that does not expose file bytes"))
    }

    private func skillText() throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    private func section(named start: String, endingAt end: String, in text: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start))
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex))
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func normalizedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
