import AppKit
import Combine
import Foundation
import XcodeWorktreeCore
import ServiceManagement

@MainActor
final class XcodeWorktreeBoard: ObservableObject {
    @Published private(set) var snapshot: WorktreeSnapshot
    @Published private(set) var sizes: [String: WorktreeSize] = [:]
    @Published private(set) var measuringIDs: Set<String> = []
    @Published private(set) var measurementErrors: [String: String] = [:]
    @Published private(set) var commitHistories: [String: [WorktreeCommit]] = [:]
    @Published private(set) var loadingCommitHistoryIDs: Set<String> = []
    @Published private(set) var commitHistoryErrors: [String: String] = [:]
    @Published private(set) var releasePreviews: [String: WorktreeChangePreview] = [:]
    @Published private(set) var loadingReleasePreviewIDs: Set<String> = []
    @Published private(set) var releasePreviewErrors: [String: String] = [:]
    @Published private(set) var releasingIDs: Set<String> = []
    @Published private(set) var releaseError: String?
    @Published private(set) var agentCommandHistory: [String]
    @Published private(set) var launchingAgentIDs: Set<String> = []
    @Published private(set) var agentLaunchError: String?
    @Published private(set) var openingTerminalPaths: Set<String> = []
    @Published private(set) var terminalOpenError: String?
    @Published private(set) var launchAtLoginStatus = SMAppService.mainApp.status
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isRefreshing = false

    private let scanner: WorktreeScanner
    private let sizer: DirectorySizer
    private let historyLoader: WorktreeHistoryLoader
    private let releaser: WorktreeReleaser
    private let agentLauncher: TerminalAgentLauncher
    private let userDefaults: UserDefaults
    private var refreshRequestedWhileBusy = false
    private var worktreeMutationGeneration: UInt64 = 0
    private static let agentCommandHistoryKey = "xcodeWorktree.agentCommandHistory.v1"

    init(
        scanner: WorktreeScanner = WorktreeScanner(),
        sizer: DirectorySizer = DirectorySizer(),
        historyLoader: WorktreeHistoryLoader = WorktreeHistoryLoader(),
        releaser: WorktreeReleaser = WorktreeReleaser(),
        agentLauncher: TerminalAgentLauncher = TerminalAgentLauncher(),
        userDefaults: UserDefaults = .standard
    ) {
        self.scanner = scanner
        self.sizer = sizer
        self.historyLoader = historyLoader
        self.releaser = releaser
        self.agentLauncher = agentLauncher
        self.userDefaults = userDefaults
        self.agentCommandHistory = AgentCommandHistory.decode(
            userDefaults.string(forKey: Self.agentCommandHistoryKey) ?? ""
        )
        self.snapshot = WorktreeSnapshot(root: WorktreeScanner.defaultRoot, items: [])
    }

    func refresh() {
        guard !isRefreshing else {
            refreshRequestedWhileBusy = true
            return
        }
        guard releasingIDs.isEmpty else {
            refreshRequestedWhileBusy = true
            return
        }

        refreshRequestedWhileBusy = false
        refreshLaunchAtLoginStatus()
        isRefreshing = true
        let scanner = scanner
        let generation = worktreeMutationGeneration

        Task { [weak self] in
            let next = await Task.detached(priority: .utility) {
                scanner.scan()
            }.value
            guard let self else { return }

            // A release can remove .git before its checkout and DerivedData are
            // fully deleted. Never publish a scan from that intermediate state.
            guard generation == self.worktreeMutationGeneration,
                  self.releasingIDs.isEmpty else {
                self.isRefreshing = false
                self.refreshRequestedWhileBusy = true
                if self.releasingIDs.isEmpty {
                    self.refreshRequestedWhileBusy = false
                    self.refresh()
                }
                return
            }

            self.snapshot = next
            self.isRefreshing = false

            let currentIDs = Set(next.items.map(\.id))
            self.sizes = self.sizes.filter { currentIDs.contains($0.key) }
            self.measurementErrors = self.measurementErrors.filter { currentIDs.contains($0.key) }
            self.measuringIDs.formIntersection(currentIDs)
            self.commitHistories = self.commitHistories.filter { currentIDs.contains($0.key) }
            self.commitHistoryErrors = self.commitHistoryErrors.filter { currentIDs.contains($0.key) }
            self.loadingCommitHistoryIDs.formIntersection(currentIDs)
            self.releasePreviews = self.releasePreviews.filter { currentIDs.contains($0.key) }
            self.releasePreviewErrors = self.releasePreviewErrors.filter { currentIDs.contains($0.key) }
            self.loadingReleasePreviewIDs.formIntersection(currentIDs)

            if self.refreshRequestedWhileBusy {
                self.refreshRequestedWhileBusy = false
                self.refresh()
            }
        }
    }

    func loadReleasePreview(_ worktree: ManagedWorktree, force: Bool = false) {
        guard !loadingReleasePreviewIDs.contains(worktree.id) else { return }
        if !force,
           releasePreviews[worktree.id] != nil || releasePreviewErrors[worktree.id] != nil {
            return
        }

        loadingReleasePreviewIDs.insert(worktree.id)
        if force {
            releasePreviews[worktree.id] = nil
        }
        releasePreviewErrors[worktree.id] = nil
        let releaser = releaser

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try releaser.previewChanges(for: worktree) }
            }.value
            guard let self else { return }
            self.loadingReleasePreviewIDs.remove(worktree.id)
            switch result {
            case .success(let preview):
                self.releasePreviews[worktree.id] = preview
            case .failure(let error):
                self.releasePreviewErrors[worktree.id] = error.localizedDescription
            }
        }
    }

    func release(_ worktree: ManagedWorktree) {
        guard worktree.health.allowsActions, releasingIDs.isEmpty else { return }
        worktreeMutationGeneration &+= 1
        releasingIDs.insert(worktree.id)
        releaseError = nil
        let releaser = releaser

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try releaser.release(worktree) }
            }.value
            guard let self else { return }
            self.releasingIDs.remove(worktree.id)
            switch result {
            case .success:
                self.refresh()
            case .failure(let error):
                self.releaseError = error.localizedDescription
                self.refresh()
            }
        }
    }

    func commitAndRelease(
        _ worktree: ManagedWorktree,
        message: String,
        expectedPreview: WorktreeChangePreview
    ) {
        guard worktree.health.allowsActions, releasingIDs.isEmpty else { return }
        worktreeMutationGeneration &+= 1
        releasingIDs.insert(worktree.id)
        releaseError = nil
        let releaser = releaser

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try releaser.commitAndRelease(
                        worktree,
                        message: message,
                        expectedPreview: expectedPreview
                    )
                }
            }.value
            guard let self else { return }
            self.releasingIDs.remove(worktree.id)
            switch result {
            case .success:
                self.refresh()
            case .failure(let error):
                self.releasePreviews[worktree.id] = nil
                self.releasePreviewErrors[worktree.id] = nil
                self.releaseError = error.localizedDescription
                self.refresh()
            }
        }
    }

    func clearReleaseError() {
        releaseError = nil
    }

    func launchAgent(_ rawCommand: String, in worktree: ManagedWorktree) {
        guard worktree.health.allowsActions,
              !launchingAgentIDs.contains(worktree.id),
              let command = AgentCommandHistory.normalizedCommand(rawCommand) else {
            agentLaunchError = "Enter a single-line command for a worktree that is safe to use."
            return
        }

        launchingAgentIDs.insert(worktree.id)
        agentLaunchError = nil
        let launcher = agentLauncher

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try launcher.launch(command: command, in: worktree.path) }
            }.value
            guard let self else { return }
            self.launchingAgentIDs.remove(worktree.id)
            switch result {
            case .success:
                self.agentCommandHistory = AgentCommandHistory.recording(
                    command,
                    in: self.agentCommandHistory
                )
                self.userDefaults.set(
                    AgentCommandHistory.encode(self.agentCommandHistory),
                    forKey: Self.agentCommandHistoryKey
                )
            case .failure(let error):
                self.agentLaunchError = error.localizedDescription
            }
        }
    }

    func clearAgentCommandHistory() {
        agentCommandHistory = []
        userDefaults.removeObject(forKey: Self.agentCommandHistoryKey)
    }

    func clearAgentLaunchError() {
        agentLaunchError = nil
    }

    func openTerminal(at directory: URL) {
        let path = directory.standardizedFileURL.path
        guard !openingTerminalPaths.contains(path) else { return }

        openingTerminalPaths.insert(path)
        terminalOpenError = nil
        let launcher = agentLauncher

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try launcher.openTerminal(in: directory) }
            }.value
            guard let self else { return }
            self.openingTerminalPaths.remove(path)
            if case .failure(let error) = result {
                self.terminalOpenError = error.localizedDescription
            }
        }
    }

    func clearTerminalOpenError() {
        terminalOpenError = nil
    }

    func measure(_ worktree: ManagedWorktree) {
        guard !measuringIDs.contains(worktree.id) else { return }
        measuringIDs.insert(worktree.id)
        measurementErrors[worktree.id] = nil
        let sizer = sizer

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try sizer.measure(worktree) }
            }.value
            guard let self else { return }
            self.measuringIDs.remove(worktree.id)
            switch result {
            case .success(let size):
                self.sizes[worktree.id] = size
            case .failure(let error):
                self.measurementErrors[worktree.id] = error.localizedDescription
            }
        }
    }

    func loadCommitHistory(_ worktree: ManagedWorktree, force: Bool = false) {
        guard !loadingCommitHistoryIDs.contains(worktree.id) else { return }
        if !force,
           commitHistories[worktree.id] != nil || commitHistoryErrors[worktree.id] != nil {
            return
        }

        loadingCommitHistoryIDs.insert(worktree.id)
        commitHistoryErrors[worktree.id] = nil
        let historyLoader = historyLoader

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try historyLoader.load(for: worktree) }
            }.value
            guard let self else { return }
            self.loadingCommitHistoryIDs.remove(worktree.id)
            switch result {
            case .success(let commits):
                self.commitHistories[worktree.id] = commits
            case .failure(let error):
                self.commitHistoryErrors[worktree.id] = error.localizedDescription
            }
        }
    }

    var launchAtLoginRequested: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func clearLaunchAtLoginError() {
        launchAtLoginError = nil
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func openInFinder(_ worktree: ManagedWorktree) {
        NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
    }

    func copyPath(_ worktree: ManagedWorktree) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.path.path, forType: .string)
    }
}
