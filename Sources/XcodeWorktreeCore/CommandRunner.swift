import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(terminationStatus: Int32, standardOutput: String, standardError: String) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout.map { max(0.1, $0) }
    }

    public func run(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let completion = ProcessCompletion()
        process.terminationHandler = { _ in
            completion.finish()
        }

        try process.run()
        let processGroupID = ownedProcessGroupID(for: process)

        // Drain both pipes concurrently. Reading them one after the other can
        // deadlock when a command fills the pipe that is not being read yet.
        let outputCapture = PipeCapture(outputPipe.fileHandleForReading)
        let errorCapture = PipeCapture(errorPipe.fileHandleForReading)
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            outputCapture.readToEnd()
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            errorCapture.readToEnd()
        }

        if let timeout {
            let deadline = DispatchTime.now() + timeout
            guard completion.wait(timeout: deadline) == .success,
                  readers.wait(timeout: deadline) == .success else {
                stopAfterTimeout(
                    process,
                    processGroupID: processGroupID,
                    completion: completion,
                    readers: readers,
                    outputCapture: outputCapture,
                    errorCapture: errorCapture
                )
                throw CommandError.timedOut(executable: executable, seconds: timeout)
            }
        } else {
            completion.wait()
            readers.wait()
        }

        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: outputCapture.data, as: UTF8.self),
            standardError: String(decoding: errorCapture.data, as: UTF8.self)
        )
    }

    private func stopAfterTimeout(
        _ process: Process,
        processGroupID: pid_t?,
        completion: ProcessCompletion,
        readers: DispatchGroup,
        outputCapture: PipeCapture,
        errorCapture: PipeCapture
    ) {
        send(SIGTERM, to: process, processGroupID: processGroupID)

        let gracefulDeadline = DispatchTime.now() + 1
        let processStopped = completion.wait(timeout: gracefulDeadline) == .success
        let readersStopped = readers.wait(timeout: gracefulDeadline) == .success
        if !processStopped || !readersStopped {
            send(SIGKILL, to: process, processGroupID: processGroupID)
            _ = completion.wait(timeout: .now() + 1)
        }

        if readers.wait(timeout: .now() + 1) == .timedOut {
            outputCapture.close()
            errorCapture.close()
        }
    }

    private func ownedProcessGroupID(for process: Process) -> pid_t? {
        // Process launches as a process-group leader on macOS. Capture that
        // relationship while it is live so timeout cleanup can include helpers.
        let identifier = process.processIdentifier
        guard identifier > 1, getpgid(identifier) == identifier else { return nil }
        return identifier
    }

    private func send(_ signal: Int32, to process: Process, processGroupID: pid_t?) {
        if let processGroupID, kill(-processGroupID, signal) == 0 {
            return
        }

        if process.isRunning {
            kill(process.processIdentifier, signal)
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let finished = DispatchGroup()

    init() {
        finished.enter()
    }

    func finish() {
        finished.leave()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        finished.wait(timeout: timeout)
    }

    func wait() {
        finished.wait()
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readToEnd() {
        data = handle.readDataToEndOfFile()
    }

    func close() {
        try? handle.close()
    }
}

public enum CommandError: Error, LocalizedError {
    case failed(executable: String, status: Int32, message: String)
    case invalidOutput(executable: String)
    case timedOut(executable: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .failed(let executable, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("git-crypt"),
               detail.localizedCaseInsensitiveContains("unable to open key file") {
                return "git-crypt is not unlocked for this worktree. Git cannot safely inspect or commit its protected files; recreate it with the current xcode-worktree skill."
            }
            return detail.isEmpty
                ? "\(executable) exited with status \(status)"
                : "\(executable) exited with status \(status): \(detail)"
        case .invalidOutput(let executable):
            return "\(executable) returned an unexpected result"
        case .timedOut(let executable, let seconds):
            return "\(executable) timed out after \(seconds.formatted()) seconds"
        }
    }
}
