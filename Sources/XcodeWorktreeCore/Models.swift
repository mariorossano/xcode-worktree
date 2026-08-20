import Foundation

public enum ManagedWorktreeLayout {
    public static let rootDirectoryName = ".xcode-worktrees"
    public static let branchPrefix = "xcode-worktree/"
}

public enum WorktreeHealth: String, Sendable {
    case valid
    case warning
    case needsAttention

    public var allowsActions: Bool {
        self != .needsAttention
    }
}

public struct ManagedWorktree: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: URL
    public let mainWorktreePath: URL?
    public let repository: String
    public let task: String
    public let branch: String?
    public let commit: String?
    public let isDirty: Bool
    public let health: WorktreeHealth
    public let issue: String?
    public let derivedDataPath: URL?

    public init(
        path: URL,
        mainWorktreePath: URL?,
        repository: String,
        task: String,
        branch: String?,
        commit: String?,
        isDirty: Bool,
        health: WorktreeHealth,
        issue: String?,
        derivedDataPath: URL?
    ) {
        self.id = path.path
        self.path = path
        self.mainWorktreePath = mainWorktreePath
        self.repository = repository
        self.task = task
        self.branch = branch
        self.commit = commit
        self.isDirty = isDirty
        self.health = health
        self.issue = issue
        self.derivedDataPath = derivedDataPath
    }
}

public struct ScanWarning: Identifiable, Equatable, Sendable {
    public let path: URL
    public let message: String

    public var id: String { path.path }

    public init(path: URL, message: String) {
        self.path = path
        self.message = message
    }
}

public struct WorktreeSnapshot: Equatable, Sendable {
    public let root: URL
    public let items: [ManagedWorktree]
    public let warnings: [ScanWarning]
    public let rootIssue: String?

    public init(
        root: URL,
        items: [ManagedWorktree],
        warnings: [ScanWarning] = [],
        rootIssue: String? = nil
    ) {
        self.root = root
        self.items = items
        self.warnings = warnings
        self.rootIssue = rootIssue
    }
}

public struct WorktreeSize: Equatable, Sendable {
    public let totalBytes: Int64
    public let derivedDataBytes: Int64
    public let checkoutBytes: Int64

    public init(totalBytes: Int64, derivedDataBytes: Int64) {
        self.totalBytes = totalBytes
        self.derivedDataBytes = derivedDataBytes
        self.checkoutBytes = max(0, totalBytes - derivedDataBytes)
    }
}
