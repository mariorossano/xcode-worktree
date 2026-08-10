import Foundation
import XCTest
@testable import XcodeWorktreeCore

final class DirectorySizerTests: XCTestCase {
    func testSizerSeparatesDerivedDataWithoutPersistingAnything() throws {
        let worktree = URL(fileURLWithPath: "/managed/worktree")
        let derivedData = worktree.appendingPathComponent("DerivedData")
        let runner = FakeRunner(values: [
            worktree.path: 100,
            derivedData.path: 25,
        ])
        let item = ManagedWorktree(
            path: worktree,
            mainWorktreePath: nil,
            repository: "repo",
            task: "task",
            branch: "xcode-worktree/task-012345abcdef",
            commit: "12345678",
            isDirty: false,
            health: .valid,
            issue: nil,
            derivedDataPath: derivedData
        )

        let result = try DirectorySizer(runner: runner).measure(item)
        XCTAssertEqual(result.totalBytes, 100 * 1_024)
        XCTAssertEqual(result.derivedDataBytes, 25 * 1_024)
        XCTAssertEqual(result.checkoutBytes, 75 * 1_024)
    }

    func testSizerCountsNestedDirectoryAlsoNamedDerivedDataAsCheckout() throws {
        let fileManager = FileManager.default
        let worktree = fileManager.temporaryDirectory
            .appendingPathComponent("directory-sizer-\(UUID().uuidString)", isDirectory: true)
        let derivedData = worktree.appendingPathComponent("DerivedData", isDirectory: true)
        let nestedDerivedData = worktree
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedDerivedData, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: worktree) }

        try Data(repeating: 0x41, count: 1_048_576)
            .write(to: derivedData.appendingPathComponent("build.bin"))
        try Data(repeating: 0x42, count: 1_048_576)
            .write(to: nestedDerivedData.appendingPathComponent("fixture.bin"))

        let item = ManagedWorktree(
            path: worktree,
            mainWorktreePath: nil,
            repository: "repo",
            task: "task",
            branch: "xcode-worktree/task-012345abcdef",
            commit: "12345678",
            isDirty: false,
            health: .valid,
            issue: nil,
            derivedDataPath: derivedData
        )

        let result = try DirectorySizer().measure(item)

        XCTAssertGreaterThanOrEqual(result.checkoutBytes, 1_048_576)
        XCTAssertGreaterThan(result.totalBytes, result.derivedDataBytes)
    }
}

private struct FakeRunner: CommandRunning {
    let values: [String: Int]

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let path = try XCTUnwrap(arguments.last)
        XCTAssertEqual(arguments, ["-sk", path])
        let value = try XCTUnwrap(values[path])
        return CommandResult(
            terminationStatus: 0,
            standardOutput: "\(value)\t\(path)\n",
            standardError: ""
        )
    }
}
