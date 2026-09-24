import AppKit
import RockyKit
import SwiftUI

/// Opens and closes the settings. Rocky ▸ Settings… (⌘,) and the sidebar's gear call `show()`.
@MainActor
@Observable
public final class SettingsPresenter {
    public static let shared = SettingsPresenter()

    public private(set) var isPresented = false
    @ObservationIgnored private var escMonitor: Any?

    public func show() {
        isPresented = true
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
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
/// 2026-09-23); Esc, a click outside it or its × closes it. A repo's own settings stay in that repo's menu.
struct SettingsModal: View {
    let model: AppModel
    private var presenter: SettingsPresenter { .shared }

    var body: some View {
        ZStack {
            if presenter.isPresented {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }
                    .transition(.opacity)
                panel
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .ignoresSafeArea()
        .animation(Theme.Motion.state, value: presenter.isPresented)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.rocky(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Close", systemImage: "xmark") { presenter.dismiss() }
                    .buttonStyle(RockyIconButtonStyle())
                    .help("Close (Esc)")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                SettingsContent(model: model)
                    .padding(24)
            }
        }
        .font(.rocky(13))
        // As large as it was as a window, smaller when the window is.
        .frame(maxWidth: Zoom.shared(620), maxHeight: Zoom.shared(600))
        .background(Color.rockyBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.composerBorder))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .accessibilityAddTraits(.isModal)
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
                section("Appearance") {
                    row("Zoom", detail: "Text and controls in every window, like a browser's zoom.") {
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
                section("Notifications") {
                    row("Sound", detail: "When an agent finishes, fails or asks you something in a workspace you are not looking at. The Dock shows how many are waiting.") {
                        alertSoundMenu
                    }
                }
                section("Terminal") {
                    row("Fold the terminal panel", detail: "Show only its bar; terminals and scripts keep running (⌘J).") {
                        Toggle("Fold the terminal panel", isOn: $panelCollapsed)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    row("Font", detail: "A Nerd Font when one is installed, for prompt icons.") {
                        Text(TerminalHostView.font(zoom: 1).displayName ?? "SF Mono")
                            .foregroundStyle(.secondary)
                    }
                }
                section("Environment") {
                    row("Login shell", detail: "Read once per launch, so every process gets your PATH and variables. Refresh after editing ~/.zshrc.") {
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
                    divider
                    row("Shell", detail: nil) {
                        Text(model.loginEnvironment["SHELL"] ?? "/bin/zsh").foregroundStyle(.secondary)
                    }
                }
                section("Agents") {
                    agentRow(.claude)
                    divider
                    agentRow(.opencode)
                    divider
                    row("OpenCode data", detail: "Its own sessions and login, apart from `~/.local/share/opencode`. Your login was copied here once.") {
                        pathLink(AgentLauncher.openCodeDataHome(prefix: model.paths.adapterPrefix))
                    }
                    divider
                    row("Updates", detail: updatesDetail) {
                        HStack(spacing: 8) {
                            if model.isCheckingAgents { CircularProgress(size: 12) }
                            SettingsButton(title: "Check Now", help: "Ask npm for the newest versions now", isEnabled: !model.isCheckingAgents) {
                                Task { await model.checkAgentUpdates(force: true) }
                            }
                        }
                    }
                    if let error = model.agentUpdateError {
                        divider
                        Text(error)
                            .font(.rocky(11))
                            .foregroundStyle(.red.opacity(0.85))
                            .padding(.vertical, 8)
                    }
                }
                section("Data") {
                    row("Database", detail: "Repos, workspaces and conversations. Secrets are in the Keychain.") {
                        pathLink(model.paths.database)
                    }
                    divider
                    row("Logs", detail: "What each agent wrote to stderr.") {
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

    /// None or one of the system's alert sounds; choosing one plays it.
    private var alertSoundMenu: some View {
        MenuButton(id: "alert-sound", placement: .belowTrailing, width: 200) { isOpen in
            HStack(spacing: 5) {
                Text(alertSound)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.rocky(9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.rocky(12))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(isOpen ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
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
        return row(kind.displayName, detail: agentDetail(kind, version)) {
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.rocky(12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14)
                .background(Theme.composer, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.composerBorder))
        }
    }

    private func row(_ title: String, detail: String?, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.rocky(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

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

/// A small button of the settings window, drawn like Rocky's other controls.
private struct SettingsButton: View {
    var title: String?
    var systemImage: String?
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    init(title: String, help: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    init(systemImage: String, help: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: Zoom.shared(14), height: Zoom.shared(14))
                } else if let title {
                    Text(title)
                }
            }
            .font(.rocky(12))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(Color.white.opacity(hovering && isEnabled ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}
