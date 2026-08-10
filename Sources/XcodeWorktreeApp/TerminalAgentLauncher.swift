import Foundation
import XcodeWorktreeCore

struct TerminalAgentLauncher: Sendable {
    enum LaunchError: LocalizedError {
        case invalidCommand
        case terminalFailed(action: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidCommand:
                return "Enter a single-line agent command."
            case .terminalFailed(let action, let detail):
                return detail.isEmpty
                    ? "Terminal could not \(action)."
                    : "Terminal could not \(action): \(detail)"
            }
        }
    }

    func launch(command rawCommand: String, in worktree: URL) throws {
        guard let command = AgentCommandHistory.normalizedCommand(rawCommand) else {
            throw LaunchError.invalidCommand
        }

        try run(
            script: Self.agentAppleScript,
            arguments: [worktree.standardizedFileURL.path, command],
            failureAction: "start the agent"
        )
    }

    func openTerminal(in directory: URL) throws {
        try run(
            script: Self.directoryAppleScript,
            arguments: [directory.standardizedFileURL.path],
            failureAction: "open the repository"
        )
    }

    private func run(
        script: String,
        arguments: [String],
        failureAction: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LaunchError.terminalFailed(action: failureAction, detail: message)
        }
    }

    private static let agentAppleScript = #"""
    on run argv
        set worktreePath to item 1 of argv
        set agentCommand to item 2 of argv
        tell application "Terminal"
            activate
            do script "cd -- " & quoted form of worktreePath & " && " & agentCommand
        end tell
    end run
    """#

    private static let directoryAppleScript = #"""
    on run argv
        set repositoryPath to item 1 of argv
        tell application "Terminal"
            activate
            do script "cd -- " & quoted form of repositoryPath
        end tell
    end run
    """#
}
