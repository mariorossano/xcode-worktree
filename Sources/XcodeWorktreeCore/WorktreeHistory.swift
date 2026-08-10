import Foundation

public struct WorktreeCommit: Identifiable, Equatable, Sendable {
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let body: String
    public let author: String
    public let authoredAt: Date

    public var id: String { hash }

    public init(
        hash: String,
        shortHash: String,
        subject: String,
        body: String,
        author: String,
        authoredAt: Date
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.body = body
        self.author = author
        self.authoredAt = authoredAt
    }
}

public struct WorktreeHistoryLoader: Sendable {
    private static let fieldCount = 6
    private let runner: any CommandRunning
    public let limit: Int

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: 15),
        limit: Int = 30
    ) {
        self.runner = runner
        self.limit = min(100, max(1, limit))
    }

    public func load(for worktree: ManagedWorktree) throws -> [WorktreeCommit] {
        let result = try runner.run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", worktree.path.path,
                "log", "-z", "--max-count=\(limit)",
                "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%b",
                "HEAD",
            ]
        )
        guard result.terminationStatus == 0 else {
            throw CommandError.failed(
                executable: "git log",
                status: result.terminationStatus,
                message: result.standardError
            )
        }
        return try Self.parse(result.standardOutput)
    }

    static func parse(_ output: String) throws -> [WorktreeCommit] {
        guard !output.isEmpty else { return [] }

        var fields = output.components(separatedBy: "\0")
        if fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count.isMultiple(of: fieldCount) else {
            throw CommandError.invalidOutput(executable: "git log")
        }

        let dateFormatter = ISO8601DateFormatter()
        return try stride(from: 0, to: fields.count, by: fieldCount).map { index in
            let hash = fields[index]
            let shortHash = fields[index + 1]
            let author = fields[index + 2]
            let authoredAt = fields[index + 3]
            let subject = fields[index + 4]
            let body = fields[index + 5].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !hash.isEmpty,
                  !shortHash.isEmpty,
                  let date = dateFormatter.date(from: authoredAt) else {
                throw CommandError.invalidOutput(executable: "git log")
            }

            return WorktreeCommit(
                hash: hash,
                shortHash: shortHash,
                subject: subject,
                body: body,
                author: author,
                authoredAt: date
            )
        }
    }
}
