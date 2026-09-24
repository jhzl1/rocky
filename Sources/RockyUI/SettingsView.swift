import AppKit
import RockyKit
import SwiftUI

/// Opens and closes the settings. Rocky ▸ Settings… (⌘,) and the sidebar's gear call `show()`. One settings panel shows
/// at a time: showing this one closes a repository's (`RepoSettingsPresenter`).
@MainActor
@Observable
public final class SettingsPresenter {
    public static let shared = SettingsPresenter()

    public private(set) var isPresented = false
    @ObservationIgnored private var escMonitor: Any?

    public func show() {
        RepoSettingsPresenter.shared.dismiss()
        isPresented = true
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            // A Rocky menu open over the panel takes this Esc alone; its own monitor closes it.
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard !MenuPresenter.isAnyMenuOpen else { return false }
                self?.dismiss()
                return true
            }
            return closed ? nil : event
        }
    }

    public func dismiss() {
        isPresented = false
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}

/// What applies to the whole app, not to one repo: the zoom, the terminal panel, the login shell environment, the
/// agents and where Rocky keeps its data. A panel over the window, not a window of its own (user decision,
/// 2026-09-23); Esc, a click outside it or its × closes it. A repo's own settings are `RepoSettingsModal`, opened from
/// that repo's menu.
struct SettingsModal: View {
    let model: AppModel
    private var presenter: SettingsPresenter { .shared }

    var body: some View {
        SettingsModalOverlay(isPresented: presenter.isPresented, onClose: { presenter.dismiss() }) {
            SettingsPanel(title: "Settings", onClose: { presenter.dismiss() }) {
                SettingsContent(model: model)
            }
        }
    }
}

/// The sections of the settings.
struct SettingsContent: View {
    let model: AppModel
    @AppStorage("terminalPanelCollapsed") private var panelCollapsed = false
    @AppStorage(AlertSound.defaultsKey) private var alertSound = AlertSound.defaultName
    @State private var refreshing = false

    private var zoom: Zoom { Zoom.shared }

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection("Appearance") {
                    SettingsRow("Zoom", detail: "Text and controls in every window, like a browser's zoom.") {
                        HStack(spacing: 6) {
                            SettingsButton(systemImage: "minus", help: "Zoom Out (⌘-)", isEnabled: zoom.canZoomOut) { zoom.zoomOut() }
                            Text(verbatim: "\(Int((zoom.scale * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(minWidth: Zoom.shared(44))
                            SettingsButton(systemImage: "plus", help: "Zoom In (⌘+)", isEnabled: zoom.canZoomIn) { zoom.zoomIn() }
                            SettingsButton(title: "Actual Size", help: "Actual Size (⌘0)", isEnabled: !zoom.isActualSize) { zoom.reset() }
                        }
                    }
                }
                SettingsSection("Notifications") {
                    SettingsRow("Sound", detail: "When an agent finishes, fails or asks you something in a workspace you are not looking at. The Dock shows how many are waiting.") {
                        alertSoundMenu
                    }
                }
                SettingsSection("Terminal") {
                    SettingsRow("Fold the terminal panel", detail: "Show only its bar; terminals and scripts keep running (⌘J).") {
                        Toggle("Fold the terminal panel", isOn: $panelCollapsed)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Font", detail: "A Nerd Font when one is installed, for prompt icons.") {
                        Text(TerminalHostView.font(zoom: 1).displayName ?? "SF Mono")
                            .foregroundStyle(.secondary)
                    }
                }
                // SET-01, after Terminal (Open question 11).
                SettingsSection("GitHub") {
                    SettingsRow(
                        "Archive a workspace when its pull request merges",
                        detail: "Runs its archive script and removes its worktree; the branch is kept. A worktree with uncommitted changes is left as it is."
                    ) {
                        Toggle("Archive a workspace when its pull request merges", isOn: archiveOnMerge)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
                SettingsSection("Environment") {
                    SettingsRow("Login shell", detail: "Read once per launch, so every process gets your PATH and variables. Refresh after editing ~/.zshrc.") {
                        HStack(spacing: 8) {
                            if refreshing { CircularProgress(size: 12) }
                            SettingsButton(title: "Refresh", help: "Read the login shell's environment again", isEnabled: !refreshing) {
                                refreshing = true
                                Task {
                                    await model.refreshEnvironment()
                                    refreshing = false
                                }
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Shell", detail: nil) {
                        Text(model.loginEnvironment["SHELL"] ?? "/bin/zsh").foregroundStyle(.secondary)
                    }
                }
                SettingsSection("Agents") {
                    agentRow(.claude)
                    SettingsDivider()
                    agentRow(.opencode)
                    SettingsDivider()
                    SettingsRow("OpenCode data", detail: "Its own sessions and login, apart from `~/.local/share/opencode`. Your login was copied here once.") {
                        pathLink(AgentLauncher.openCodeDataHome(prefix: model.paths.adapterPrefix))
                    }
                    SettingsDivider()
                    SettingsRow("Updates", detail: updatesDetail) {
                        HStack(spacing: 8) {
                            if model.isCheckingAgents { CircularProgress(size: 12) }
                            SettingsButton(title: "Check Now", help: "Ask npm for the newest versions now", isEnabled: !model.isCheckingAgents) {
                                Task { await model.checkAgentUpdates(force: true) }
                            }
                        }
                    }
                    if let error = model.agentUpdateError {
                        SettingsDivider()
                        Text(error)
                            .font(.rocky(11))
                            .foregroundStyle(.red.opacity(0.85))
                            .padding(.vertical, 8)
                    }
                }
                SettingsSection("Data") {
                    SettingsRow("Database", detail: "Repos, workspaces and conversations. Secrets are in the Keychain.") {
                        pathLink(model.paths.database)
                    }
                    SettingsDivider()
                    SettingsRow("Logs", detail: "What each agent wrote to stderr.") {
                        pathLink(model.paths.logs)
                    }
                }
            }
            .task {
                // The window opens after a day without a check: the daily check runs now.
                model.refreshInstalledAgentVersions()
                await model.checkAgentUpdates()
            }
    }

    /// SET-01's switch, kept by the model in UserDefaults ("archiveOnMerge").
    private var archiveOnMerge: Binding<Bool> {
        let model = self.model
        return Binding(get: { model.archiveOnMerge }, set: { model.archiveOnMerge = $0 })
    }

    /// None or one of the system's alert sounds; choosing one plays it.
    private var alertSoundMenu: some View {
        MenuButton(id: "alert-sound", placement: .belowTrailing, width: 200) { isOpen in
            SettingsMenuLabel(title: alertSound, isOpen: isOpen)
        } content: {
            MenuItem(title: AlertSound.none, isChecked: alertSound == AlertSound.none) { alertSound = AlertSound.none }
            MenuDivider()
            ForEach(AlertSound.available, id: \.self) { name in
                MenuItem(title: name, isChecked: alertSound == name) {
                    alertSound = name
                    AlertSound.play(name)
                }
            }
        }
        .help("The alert sound")
    }

    /// "Installed 0.81.0 (Claude Code 2.1.280) · newest 0.81.1", and Update, Use Tested Version or Up to date.
    private func agentRow(_ kind: AgentKind) -> some View {
        let version = model.agentVersions[kind] ?? AgentVersion(installed: nil, tested: AgentLauncher.testedVersion(for: kind))
        return SettingsRow(kind.displayName, detail: agentDetail(kind, version)) {
            HStack(spacing: 8) {
                if model.updatingAgent == kind {
                    CircularProgress(size: 12)
                    Text("Installing…").foregroundStyle(.secondary)
                } else if version.updateAvailable, let latest = version.latest {
                    SettingsButton(title: "Update to \(latest)", help: "Install \(AgentLauncher.package(for: kind))@\(latest)", isEnabled: model.updatingAgent == nil) {
                        Task { await model.updateAgent(kind) }
                    }
                } else if version.latest != nil, version.installed != nil {
                    Text("Up to date").foregroundStyle(.secondary)
                }
                if version.isOffTested, model.updatingAgent != kind {
                    SettingsButton(title: "Use \(version.tested)", help: "Go back to the version this build of Rocky was tested with", isEnabled: model.updatingAgent == nil) {
                        Task { await model.updateAgent(kind, toTested: true) }
                    }
                }
            }
        }
    }

    private func agentDetail(_ kind: AgentKind, _ version: AgentVersion) -> String {
        guard let installed = version.installed else {
            return "Not installed yet: Rocky installs \(AgentLauncher.package(for: kind)) \(version.tested) the first time you open one of its conversations."
        }
        var parts = ["Installed \(installed)" + (version.claudeCode.map { " (Claude Code \($0))" } ?? "")]
        if let latest = version.latest, latest != installed { parts.append("newest \(latest)") }
        if installed != version.tested { parts.append("tested \(version.tested)") }
        return parts.joined(separator: " · ")
    }

    private var updatesDetail: String {
        let last = model.lastAgentCheck.map { "Last checked \(Self.relative.localizedString(for: $0, relativeTo: Date()))." } ?? "Not checked yet."
        return "Rocky asks npm once a day on its own. \(last) New conversations use an update; open ones keep their version until restarted."
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// A path, shortened to its last parts, that shows the file in Finder.
    private func pathLink(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "arrow.up.forward")
                    .font(.rocky(9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: Zoom.shared(260), alignment: .trailing)
        }
        .buttonStyle(.plain)
        .clickable()
        .help("Show \(url.path) in Finder")
    }
}
