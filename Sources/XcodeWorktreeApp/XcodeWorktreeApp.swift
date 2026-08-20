import AppKit
import XcodeWorktreeCore
import SwiftUI

private extension Color {
    static let worktreeCream = Color(red: 0.95, green: 0.83, blue: 0.62)
}

@MainActor
private enum BrandIcon {
    static let statusBar = make(
        size: NSSize(width: 20, height: 18),
        strokeColor: .black,
        isTemplate: true
    )
    static let statusBarAttention = make(
        size: NSSize(width: 20, height: 18),
        strokeColor: .systemOrange,
        isTemplate: false
    )
    static let emptyState = make(
        size: NSSize(width: 52, height: 52),
        strokeColor: .black,
        isTemplate: true
    )

    private static func make(
        size: NSSize,
        strokeColor: NSColor,
        isTemplate: Bool
    ) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = min(rect.width / 24, rect.height / 24)
            let xOffset = rect.minX + (rect.width - 24 * scale) / 2
            let yOffset = rect.minY + (rect.height - 24 * scale) / 2

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }

            func circle(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) -> CGRect {
                CGRect(
                    x: xOffset + (centerX - radius) * scale,
                    y: yOffset + (centerY - radius) * scale,
                    width: radius * 2 * scale,
                    height: radius * 2 * scale
                )
            }

            let path = NSBezierPath()
            path.lineWidth = 1.55 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            for topY in [CGFloat(1.2), 6.6, 12] {
                path.move(to: point(12, topY))
                path.line(to: point(21, topY + 4.6))
                path.line(to: point(12, topY + 9.2))
                path.line(to: point(3, topY + 4.6))
                path.close()
            }

            path.move(to: point(12, 21.2))
            path.line(to: point(12, 7.6))
            path.line(to: point(7.6, 4.5))
            path.move(to: point(12, 7.6))
            path.line(to: point(16.4, 4.5))

            strokeColor.setStroke()
            path.stroke()

            let nodes = NSBezierPath()
            nodes.appendOval(in: circle(centerX: 7.6, centerY: 4.5, radius: 1.15))
            nodes.appendOval(in: circle(centerX: 16.4, centerY: 4.5, radius: 1.15))
            strokeColor.setFill()
            nodes.fill()
            return true
        }
        image.isTemplate = isTemplate
        return image
    }
}

@main
struct XcodeWorktreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var board = XcodeWorktreeBoard()

    var body: some Scene {
        MenuBarExtra {
            BoardView(presentation: .menuBar)
                .environmentObject(board)
        } label: {
            Image(nsImage: needsAttention ? BrandIcon.statusBarAttention : BrandIcon.statusBar)
                .accessibilityLabel(
                    needsAttention
                        ? "Xcode Worktree needs attention"
                        : "Xcode Worktree"
                )
        }
        .menuBarExtraStyle(.window)
    }

    private var needsAttention: Bool {
        board.snapshot.rootIssue != nil
            || !board.snapshot.warnings.isEmpty
            || board.snapshot.items.contains(where: { $0.health == .needsAttention })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class BoardWindowController: NSObject {
    static let shared = BoardWindowController()
    private var window: NSWindow?

    func show(board: XcodeWorktreeBoard) {
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = BoardView(presentation: .window)
            .environmentObject(board)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Xcode Worktree"
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 410, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("XcodeWorktreeMainWindow")
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum BoardPresentation {
    case menuBar
    case window
}

private struct BoardView: View {
    private static let refreshInterval: Duration = .seconds(60)

    @EnvironmentObject private var board: XcodeWorktreeBoard
    @Environment(\.colorScheme) private var colorScheme
    let presentation: BoardPresentation
    @State private var collapsedRepositoryIDs: Set<String> = []
    @State private var selectedWorktree: ManagedWorktree?
    @State private var pendingRelease: ManagedWorktree?
    @State private var pendingAgentLaunch: ManagedWorktree?
    @State private var overviewContentHeight: CGFloat = 120

    var body: some View {
        Group {
            if let pendingRelease {
                WorktreeReleaseConfirmationView(
                    worktree: pendingRelease,
                    onDiscard: {
                        self.pendingRelease = nil
                        board.release(pendingRelease)
                    },
                    onCommit: { message, preview in
                        self.pendingRelease = nil
                        board.commitAndRelease(
                            pendingRelease,
                            message: message,
                            expectedPreview: preview
                        )
                    },
                    onCancel: {
                        self.pendingRelease = nil
                    }
                )
                .environmentObject(board)
                .id(pendingRelease.id)
            } else if let pendingAgentLaunch {
                AgentLaunchView(
                    worktree: pendingAgentLaunch,
                    onLaunch: { command in
                        self.pendingAgentLaunch = nil
                        board.launchAgent(command, in: pendingAgentLaunch)
                    },
                    onCancel: {
                        self.pendingAgentLaunch = nil
                    }
                )
                .environmentObject(board)
                .id(pendingAgentLaunch.id)
            } else if let selectedWorktree {
                WorktreeDetailView(worktree: selectedWorktree) {
                    self.selectedWorktree = nil
                }
                .environmentObject(board)
            } else {
                overview
            }
        }
        .frame(
            minWidth: 410,
            idealWidth: presentation == .window ? 620 : 410,
            maxWidth: presentation == .window ? .infinity : 410
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            board.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                board.refresh()
            }
        }
        .onDisappear {
            pendingRelease = nil
            pendingAgentLaunch = nil
        }
        .alert(
            "Launch at Login",
            isPresented: Binding(
                get: { board.launchAtLoginError != nil },
                set: { if !$0 { board.clearLaunchAtLoginError() } }
            )
        ) {
            Button("OK") {
                board.clearLaunchAtLoginError()
            }
        } message: {
            Text(board.launchAtLoginError ?? "Unknown error")
        }
        .alert(
            "Couldn’t Complete Worktree Operation",
            isPresented: Binding(
                get: { board.releaseError != nil },
                set: { if !$0 { board.clearReleaseError() } }
            )
        ) {
            Button("OK") {
                board.clearReleaseError()
            }
        } message: {
            Text(board.releaseError ?? "Unknown error")
        }
        .alert(
            "Couldn’t Launch Agent",
            isPresented: Binding(
                get: { board.agentLaunchError != nil },
                set: { if !$0 { board.clearAgentLaunchError() } }
            )
        ) {
            Button("OK") {
                board.clearAgentLaunchError()
            }
        } message: {
            Text(board.agentLaunchError ?? "Unknown error")
        }
        .alert(
            "Couldn’t Open Terminal",
            isPresented: Binding(
                get: { board.terminalOpenError != nil },
                set: { if !$0 { board.clearTerminalOpenError() } }
            )
        ) {
            Button("OK") {
                board.clearTerminalOpenError()
            }
        } message: {
            Text(board.terminalOpenError ?? "Unknown error")
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if board.isRefreshing
                && board.snapshot.items.isEmpty
                && board.snapshot.warnings.isEmpty
                && board.snapshot.rootIssue == nil {
                loadingState
            } else if board.snapshot.items.isEmpty && board.snapshot.warnings.isEmpty {
                emptyState
            } else {
                if presentation == .window {
                    worktreeList
                        .frame(maxHeight: .infinity)
                } else {
                    worktreeList
                        .frame(height: fittedOverviewHeight)
                }
            }

            Divider()
            footer
        }
        .frame(maxHeight: presentation == .window ? .infinity : nil, alignment: .top)
    }

    private var worktreeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(repositoryGroups) { group in
                    repositoryHeader(group)

                    if isExpanded(group) {
                        ForEach(group.worktrees) { worktree in
                            WorktreeRow(
                                worktree: worktree,
                                onOpen: {
                                    selectedWorktree = worktree
                                    board.loadCommitHistory(worktree, force: true)
                                },
                                onLaunchAgent: {
                                    pendingAgentLaunch = worktree
                                },
                                onRequestRelease: {
                                    pendingRelease = worktree
                                }
                            )
                            .environmentObject(board)
                        }
                    }
                }

                ForEach(board.snapshot.warnings) { warning in
                    WarningCard(warning: warning)
                }
            }
            .padding(12)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                if height > 0 {
                    overviewContentHeight = height
                }
            }
        }
    }

    private var repositoryGroups: [RepositoryGroup] {
        Dictionary(grouping: board.snapshot.items) { worktree in
            worktree.mainWorktreePath?.standardizedFileURL.path
                ?? "unresolved:\(worktree.repository)"
        }
        .compactMap { _, worktrees in
            guard let first = worktrees.first else { return nil }
            return RepositoryGroup(
                name: first.repository,
                mainWorktreePath: first.mainWorktreePath,
                worktrees: worktrees
            )
        }
        .sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return ($0.mainWorktreePath?.path ?? "") < ($1.mainWorktreePath?.path ?? "")
        }
    }

    private var fittedOverviewHeight: CGFloat {
        min(520, overviewContentHeight)
    }

    private func repositoryHeader(_ group: RepositoryGroup) -> some View {
        let expanded = isExpanded(group)

        return HStack(spacing: 7) {
            Button {
                if expanded {
                    collapsedRepositoryIDs.insert(group.id)
                } else {
                    collapsedRepositoryIDs.remove(group.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(
                                colorScheme == .dark
                                    ? Color.worktreeCream
                                    : Color.primary
                            )

                        if let path = group.displayPath {
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(group.mainWorktreePath?.path ?? path)
                        }
                    }

                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(expanded ? "Collapse repository" : "Expand repository")
            .accessibilityLabel("\(group.name), \(group.worktrees.count) worktrees")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            Text("\(group.worktrees.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            if let path = group.mainWorktreePath {
                let pathKey = path.standardizedFileURL.path
                Button {
                    board.openTerminal(at: path)
                } label: {
                    Group {
                        if board.openingTerminalPaths.contains(pathKey) {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(board.openingTerminalPaths.contains(pathKey))
                .help("Open repository in Terminal")
                .accessibilityLabel("Open \(group.name) repository in Terminal")
            }
        }
        .padding(.horizontal, 2)
    }

    private func isExpanded(_ group: RepositoryGroup) -> Bool {
        !collapsedRepositoryIDs.contains(group.id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Xcode Worktrees")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if presentation == .menuBar {
                Button {
                    BoardWindowController.shared.show(board: board)
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open as Window")
                .accessibilityLabel("Open Xcode Worktree as a window")
            }

            Button {
                board.refresh()
            } label: {
                Group {
                    if board.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(board.isRefreshing)
            .help(board.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel("Refresh worktrees")
        }
        .padding(12)
    }

    private var summary: String {
        if board.isRefreshing && board.snapshot.items.isEmpty {
            return "Scanning Xcode worktrees…"
        }

        if board.snapshot.rootIssue != nil {
            return "Needs attention"
        }

        let worktreeCount = board.snapshot.items.count
        let warnings = board.snapshot.items.filter { $0.health == .warning }.count
        let attention = board.snapshot.items.filter { $0.health == .needsAttention }.count
            + board.snapshot.warnings.count
        let worktrees = worktreeCount == 1 ? "1 Xcode worktree" : "\(worktreeCount) Xcode worktrees"
        if attention == 0 {
            if warnings == 0 {
                return worktrees
            }
            let warningLabel = warnings == 1 ? "1 warning" : "\(warnings) warnings"
            return "\(worktrees) · \(warningLabel)"
        }
        let usable = board.snapshot.items.filter { $0.health.allowsActions }.count
        return "\(usable) usable · \(attention) need attention"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if board.snapshot.rootIssue == nil {
                Image(nsImage: BrandIcon.emptyState)
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
            Text(board.snapshot.rootIssue == nil ? "No Xcode worktrees" : "Xcode Worktree unavailable")
                .font(.headline)
            Text(board.snapshot.rootIssue ?? "Ask an agent to create an isolated worktree for Xcode work.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding()
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning Xcode worktrees…")
                .font(.headline)
            Text("macOS may ask for access when a repository is in Documents or Desktop. Close this panel if the permission dialog is behind it.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding()
    }

    private var footer: some View {
        HStack {
            Text("~/\(ManagedWorktreeLayout.rootDirectoryName)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Menu {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { board.launchAtLoginRequested },
                        set: { board.setLaunchAtLogin($0) }
                    )
                )

                if board.launchAtLoginRequiresApproval {
                    Divider()
                    Text("Approval required in System Settings")
                    Button("Open Login Items Settings") {
                        board.openLoginItemsSettings()
                    }
                }
            } label: {
                Image(systemName: board.launchAtLoginRequiresApproval
                      ? "gearshape.badge.exclamationmark"
                      : "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Xcode Worktree settings")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }
}

private struct AgentLaunchView: View {
    @EnvironmentObject private var board: XcodeWorktreeBoard
    let worktree: ManagedWorktree
    let onLaunch: (String) -> Void
    let onCancel: () -> Void
    @State private var command = ""
    @FocusState private var commandIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Label("Launch an agent in this worktree", systemImage: "terminal")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 5) {
                    Text("AGENT COMMAND")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    TextField("Enter an agent command", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .focused($commandIsFocused)
                        .onSubmit(launchIfPossible)
                }

                if !board.agentCommandHistory.isEmpty {
                    Menu {
                        ForEach(board.agentCommandHistory, id: \.self) { recentCommand in
                            Button(recentCommand) {
                                command = recentCommand
                            }
                        }

                        Divider()

                        Button("Clear Command History", role: .destructive) {
                            board.clearAgentCommandHistory()
                            command = ""
                            commandIsFocused = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Choose from recent commands")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Commands you launch will appear here for the next worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(worktree.path.path)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text("A new Terminal window will start here. The exact command is saved locally in history, so do not include secrets. Use only one active agent per worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: launchIfPossible) {
                    HStack(spacing: 6) {
                        if board.launchingAgentIDs.contains(worktree.id) {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Launch Agent")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canLaunch)
            }
            .padding(12)
        }
        .onAppear {
            if command.isEmpty {
                command = board.agentCommandHistory.first ?? ""
            }
            commandIsFocused = true
        }
        .onExitCommand(perform: onCancel)
    }

    private var canLaunch: Bool {
        AgentCommandHistory.normalizedCommand(command) != nil
            && worktree.health.allowsActions
            && !board.launchingAgentIDs.contains(worktree.id)
    }

    private func launchIfPossible() {
        guard canLaunch else { return }
        onLaunch(command)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to worktrees")
            .accessibilityLabel("Back to worktrees")

            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.task)
                    .font(.headline)
                    .lineLimit(1)
                Text(worktree.repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
    }
}

private struct WorktreeReleaseConfirmationView: View {
    @EnvironmentObject private var board: XcodeWorktreeBoard
    let worktree: ManagedWorktree
    let onDiscard: () -> Void
    let onCommit: (String, WorktreeChangePreview) -> Void
    let onCancel: () -> Void
    @State private var commitMessage: String

    init(
        worktree: ManagedWorktree,
        onDiscard: @escaping () -> Void,
        onCommit: @escaping (String, WorktreeChangePreview) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.worktree = worktree
        self.onDiscard = onDiscard
        self.onCommit = onCommit
        self.onCancel = onCancel
        _commitMessage = State(initialValue: "Preserve \(worktree.task) worktree changes")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Remove this worktree?", systemImage: "trash")
                        .font(.headline)

                    Text("The checkout and all its local ignored files, including local Xcode DerivedData, will be removed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    branchCard
                    previewContent

                    Text("Continue only if no agent or build is using this worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .frame(height: contentHeight)

            Divider()
            actions
        }
        .onAppear {
            board.loadReleasePreview(worktree, force: true)
        }
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Cancel removal")
            .accessibilityLabel("Cancel removal")

            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.task)
                    .font(.headline)
                    .lineLimit(1)
                Text(worktree.repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var branchCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BRANCH PRESERVED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(worktree.branch ?? "Current branch")
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var previewContent: some View {
        if isLoadingPreview {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading current Git changes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let error = board.releasePreviewErrors[worktree.id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("Changes could not be listed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    board.loadReleasePreview(worktree, force: true)
                }
            }
        } else if let preview = preview {
            if preview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No tracked or untracked changes to commit", systemImage: "checkmark.circle")
                        .font(.callout.weight(.semibold))
                    Text("Ignored files are not committed and will be removed with the checkout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("CHANGES TO PRESERVE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    changeGroup(
                        title: "Already staged",
                        icon: "checkmark.circle",
                        paths: preview.stagedPaths
                    )
                    changeGroup(
                        title: "Tracked changes to add",
                        icon: "pencil",
                        paths: preview.trackedPathsToStage
                    )
                    changeGroup(
                        title: "Untracked files to add",
                        icon: "plus.circle",
                        paths: preview.untrackedPathsToAdd
                    )

                    Label(
                        "Ignored files, including DerivedData, are excluded from the commit.",
                        systemImage: "eye.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("COMMIT MESSAGE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        TextField("Commit message", text: $commitMessage)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private func changeGroup(title: String, icon: String, paths: [String]) -> some View {
        Group {
            if !paths.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("\(title) (\(paths.count))", systemImage: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .foregroundStyle(.tertiary)
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isLoadingPreview || board.releasePreviewErrors[worktree.id] != nil {
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()
            }
            .padding(12)
        } else if let preview, !preview.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Remove Without Commit", role: .destructive, action: onDiscard)
                }

                Button {
                    onCommit(commitMessage, preview)
                } label: {
                    Text("Commit & Remove")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        } else {
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(
                    worktree.isDirty ? "Remove Without Commit" : "Remove Worktree",
                    role: .destructive,
                    action: onDiscard
                )
            }
            .padding(12)
        }
    }

    private var preview: WorktreeChangePreview? {
        board.releasePreviews[worktree.id]
    }

    private var isLoadingPreview: Bool {
        board.loadingReleasePreviewIDs.contains(worktree.id)
    }

    private var contentHeight: CGFloat {
        if worktree.isDirty || preview?.isEmpty == false || isLoadingPreview {
            return 390
        }
        return 250
    }
}

private struct RepositoryGroup: Identifiable {
    let name: String
    let mainWorktreePath: URL?
    let worktrees: [ManagedWorktree]

    var id: String { mainWorktreePath?.path ?? "unresolved:\(name)" }

    var displayPath: String? {
        guard let path = mainWorktreePath?.standardizedFileURL.path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct WorktreeRow: View {
    @EnvironmentObject private var board: XcodeWorktreeBoard
    let worktree: ManagedWorktree
    let onOpen: () -> Void
    let onLaunchAgent: () -> Void
    let onRequestRelease: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onOpen()
            } label: {
                rowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recent commits")
            .accessibilityLabel("\(worktree.task), \(worktree.repository). Show recent commits")

            actionButtons
                .padding(.top, 9)
                .padding(.trailing, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .accessibilityElement(children: .contain)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if worktree.health != .valid {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(
                            worktree.health == .warning ? "Warning" : "Needs attention"
                        )
                }

                Text(worktree.task)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if worktree.isDirty {
                    Text("DIRTY")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }
            .padding(.trailing, 112)

            if worktree.branch != nil || worktree.commit != nil {
                HStack(spacing: 6) {
                    if let branch = worktree.branch {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if let commit = worktree.commit {
                        Text(commit)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }

            if let issue = worktree.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let size = board.sizes[worktree.id] {
                sizeSummary(size)
            } else if let error = board.measurementErrors[worktree.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button(action: onLaunchAgent) {
                Group {
                    if board.launchingAgentIDs.contains(worktree.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "terminal")
                    }
                }
                .frame(width: 20, height: 20)
            }
            .disabled(!worktree.health.allowsActions || board.launchingAgentIDs.contains(worktree.id))
            .help(worktree.health.allowsActions
                  ? "Launch an agent in this worktree"
                  : "Resolve this worktree issue before launching an agent")
            .accessibilityLabel("Launch an agent in this worktree")

            Button {
                board.openInFinder(worktree)
            } label: {
                Image(systemName: "folder")
                    .frame(width: 20, height: 20)
            }
            .help("Open in Finder")
            .accessibilityLabel("Open in Finder")

            Button {
                board.copyPath(worktree)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 20, height: 20)
            }
            .help("Copy path")
            .accessibilityLabel("Copy path")

            Button {
                board.measure(worktree)
            } label: {
                Group {
                    if board.measuringIDs.contains(worktree.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "externaldrive")
                    }
                }
                .frame(width: 20, height: 20)
            }
            .disabled(board.measuringIDs.contains(worktree.id))
            .help("Measure disk use")
            .accessibilityLabel("Measure disk use")

            Button {
                onRequestRelease()
            } label: {
                Group {
                    if board.releasingIDs.contains(worktree.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .frame(width: 20, height: 20)
            }
            .disabled(!worktree.health.allowsActions || !board.releasingIDs.isEmpty)
            .help(worktree.health.allowsActions
                  ? "Remove worktree and preserve branch"
                  : "Resolve this worktree issue before removing it")
            .accessibilityLabel("Remove worktree and preserve branch")
        }
        .buttonStyle(.borderless)
    }

    private func sizeSummary(_ size: WorktreeSize) -> some View {
        HStack(spacing: 10) {
            Text("Total \(format(size.totalBytes))")
            if size.derivedDataBytes > 0 {
                Text("DerivedData \(format(size.derivedDataBytes))")
                Text("Checkout \(format(size.checkoutBytes))")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct WorktreeDetailView: View {
    @EnvironmentObject private var board: XcodeWorktreeBoard
    let worktree: ManagedWorktree
    let onBack: () -> Void
    @State private var detailContentHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    worktreeSummary

                    Text("Recent commits")
                        .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                    historyContent
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    if height > 0 {
                        detailContentHeight = height
                    }
                }
            }
            .frame(height: fittedDetailHeight)
        }
        .onAppear {
            board.loadCommitHistory(worktree)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to worktrees")
            .accessibilityLabel("Back to worktrees")

            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.task)
                    .font(.headline)
                    .lineLimit(1)
                Text(worktree.repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                board.loadCommitHistory(worktree, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help("Refresh commits")
            .accessibilityLabel("Refresh commits")
        }
        .padding(12)
    }

    private var worktreeSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let branch = worktree.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Label {
                Text(worktree.path.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .help(worktree.path.path)

            if worktree.isDirty {
                Label("Also contains uncommitted changes", systemImage: "pencil.and.list.clipboard")
                    .foregroundStyle(.orange)
            }

            if let issue = worktree.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var historyContent: some View {
        if let error = board.commitHistoryErrors[worktree.id] {
            VStack(spacing: 10) {
                Label("Commit history unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    board.loadCommitHistory(worktree, force: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding()
        } else if let commits = board.commitHistories[worktree.id] {
            if commits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No commits reachable from HEAD")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(commits) { commit in
                    CommitRow(commit: commit)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading commits…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    private var isLoading: Bool {
        board.loadingCommitHistoryIDs.contains(worktree.id)
    }

    private var fittedDetailHeight: CGFloat {
        min(520, detailContentHeight)
    }
}

private struct CommitRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let commit: WorktreeCommit
    @State private var showsMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(commit.shortHash)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(
                        colorScheme == .dark
                            ? Color.worktreeCream
                            : Color.accentColor
                    )
                    .help(commit.hash)

                Spacer()

                Text(commit.authoredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsMessage.toggle()
                    }
                } label: {
                    Image(systemName: showsMessage ? "text.bubble.fill" : "text.bubble")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(showsMessage ? "Hide commit message" : "Show commit message")
                .accessibilityLabel(showsMessage ? "Hide commit message" : "Show commit message")
            }

            Text(commit.subject.isEmpty ? "(No commit subject)" : commit.subject)
                .font(.callout.weight(.medium))
                .lineLimit(2)

            Text(commit.author.isEmpty ? "Unknown author" : commit.author)
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsMessage {
                Divider()
                    .padding(.vertical, 2)

                Text(commit.body.isEmpty ? "No additional commit message." : commit.body)
                    .font(.caption)
                    .foregroundStyle(commit.body.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WarningCard: View {
    let warning: ScanWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Folder skipped", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(warning.path.lastPathComponent)
                .font(.caption.monospaced())
            Text(warning.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
