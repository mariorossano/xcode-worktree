import Foundation

public struct DirectorySizer: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func measure(_ worktree: ManagedWorktree) throws -> WorktreeSize {
        guard let derivedDataPath = worktree.derivedDataPath else {
            let checkout = try allocatedBytes(at: worktree.path)
            return WorktreeSize(totalBytes: checkout, derivedDataBytes: 0)
        }

        let derivedData = try allocatedBytes(at: derivedDataPath)
        let total = try allocatedBytes(at: worktree.path)
        return WorktreeSize(
            totalBytes: total,
            derivedDataBytes: derivedData
        )
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        let result = try runner.run(
            executable: "/usr/bin/du",
            arguments: ["-sk", url.path]
        )
        guard result.terminationStatus == 0 else {
            throw CommandError.failed(
                executable: "du",
                status: result.terminationStatus,
                message: result.standardError
            )
        }

        guard let firstField = result.standardOutput.split(whereSeparator: { $0.isWhitespace }).first,
              let kibibytes = Int64(firstField) else {
            throw CommandError.invalidOutput(executable: "du")
        }

        return kibibytes * 1_024
    }
}
