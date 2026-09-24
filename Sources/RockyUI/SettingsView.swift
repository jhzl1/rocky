import AppKit
import RockyKit
import SwiftUI

/// Rocky ▸ Settings… (⌘,): what applies to the whole app, not to one repo. The zoom, the terminal panel, the login
/// shell environment, which agents Rocky runs, and where it keeps its data. A repo's own settings (scripts,
/// variables, Claude instance) stay in that repo's menu.
public struct SettingsView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            SettingsContent(model: model)
                .padding(24)
        }
        .font(.rocky(13))
        .frame(width: Zoom.shared(620), height: Zoom.shared(560))
        .background(Color.rockyBackground)
        .preferredColorScheme(.dark)
    }
}

/// The sections of the settings window.
struct SettingsContent: View {
    let model: AppModel
    @AppStorage("terminalPanelCollapsed") private var panelCollapsed = false
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
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}
