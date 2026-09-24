import AppKit
import RockyKit
import SwiftUI

/// Opens and closes a repository's settings (`RepoSettingsModal`). The repository menu's Settings… calls
/// `show(repoId:)`. One settings panel shows at a time: showing this one closes the app's (`SettingsPresenter`).
@MainActor
@Observable
final class RepoSettingsPresenter {
    static let shared = RepoSettingsPresenter()

    /// The repository whose settings are open; nil while they are closed.
    private(set) var repoId: String?
    @ObservationIgnored private var escMonitor: Any?

    var isPresented: Bool { repoId != nil }

    func show(repoId: String) {
        SettingsPresenter.shared.dismiss()
        self.repoId = repoId
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            // A Rocky menu open over the panel (the run mode, the Claude instance, the account) takes this Esc alone;
            // its own monitor closes it.
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard !MenuPresenter.isAnyMenuOpen else { return false }
                self?.dismiss()
                return true
            }
            return closed ? nil : event
        }
    }

    func dismiss() {
        repoId = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}

/// A repository's settings, a panel over the window like the app's Settings instead of the sheet they were (user
/// request, 2026-09-23). Esc, a click outside it, its × or Cancel close it without saving; Save (⌘S) applies every
/// section at once. Rocky's menus in it are `RootView`'s, drawn over it.
struct RepoSettingsModal: View {
    let model: AppModel
    private var presenter: RepoSettingsPresenter { .shared }

    var body: some View {
        SettingsModalOverlay(isPresented: presenter.isPresented, onClose: { presenter.dismiss() }) {
            if let repoId = presenter.repoId, let repo = model.repo(id: repoId) {
                RepoSettingsView(model: model, repo: repo, onClose: { presenter.dismiss() })
                    // Another repository's settings start from that repository's values.
                    .id(repo.id)
            }
        }
    }
}

/// The sections of a repository's settings, edited as drafts until Save.
struct RepoSettingsView: View {
    let model: AppModel
    let repo: Repo
    let onClose: () -> Void
    @State private var claudeConfigDir: String
    @State private var setupScript: String
    @State private var runScript: String
    @State private var archiveScript: String
    @State private var runMode: RunScriptMode
    /// The linked files' defaults turned off, and the user's own paths and globs (`LinkedPaths.Setting`).
    @State private var disabledDefaults: Set<String>
    @State private var linkedEntries: [String]
    /// The add field of the linked files, and why its last entry was refused.
    @State private var newLinkedPath = ""
    @State private var linkedPathProblem: LinkedPathProblem?
    @State private var variables: [VariableDraft]
    @State private var removedNames: [String] = []
    /// The account picked here; nil is "Automatic" (ACC-01's default).
    @State private var githubLogin: String?
    /// gh's logins; nil while they load.
    @State private var githubLogins: [String]?
    /// The login "Automatic" resolves to.
    @State private var automaticLogin: String?
    /// Why there is no account to pick: gh is missing, or it has no account.
    @State private var githubProblem: String?
    /// The Claude Code config directories in the home folder, read when the settings open.
    @State private var instances: [String] = []

    /// One editable variable row. A saved secret's value is never read back into the form: an empty field keeps it.
    struct VariableDraft: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var isSecret: Bool
        let savedName: String?
        let savedAsSecret: Bool
    }

    init(model: AppModel, repo: Repo, onClose: @escaping () -> Void) {
        self.model = model
        self.repo = repo
        self.onClose = onClose
        let linked = LinkedPaths.Setting(text: repo.linkedPaths)
        _claudeConfigDir = State(initialValue: repo.claudeConfigDir ?? "")
        _setupScript = State(initialValue: repo.setupScript ?? "")
        _runScript = State(initialValue: repo.runScript ?? "")
        _archiveScript = State(initialValue: repo.archiveScript ?? "")
        _runMode = State(initialValue: RunScriptMode(rawValue: repo.runScriptMode ?? "") ?? .concurrent)
        _disabledDefaults = State(initialValue: linked.disabledDefaults)
        _linkedEntries = State(initialValue: linked.entries)
        _githubLogin = State(initialValue: repo.githubLogin)
        _variables = State(initialValue: model.repoVars(repoId: repo.id).map {
            VariableDraft(name: $0.name, value: $0.value ?? "", isSecret: $0.isSecret, savedName: $0.name, savedAsSecret: $0.isSecret)
        })
    }

    var body: some View {
        SettingsPanel(title: "\(repo.name) Settings", onClose: onClose) {
            VStack(alignment: .leading, spacing: 18) {
                scriptsSection
                variablesSection
                claudeSection
                githubSection
                linkedFilesSection
            }
        } footer: {
            footer
        }
        .task {
            instances = ClaudeInstances.detect(home: FileManager.default.homeDirectoryForCurrentUser)
            await loadGitHubAccounts()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(RockyTextButtonStyle())
                    .help("Close without saving (Esc)")
                Button("Save") { save() }
                    .buttonStyle(RockyFilledButtonStyle())
                    // Not Return: it adds a linked path in the add field.
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save (⌘S)")
            }
            .font(.rocky(13))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// A line of the section it is in: a note or a warning under a row.
    private func note(_ text: String, color: Color = Theme.textTertiary) -> some View {
        Text(verbatim: text)
            .font(.rocky(11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
    }

    // MARK: Scripts

    private var scriptsSection: some View {
        SettingsSection("Scripts") {
            SettingsRow("Setup", verbatimDetail: "Runs once, when a workspace is created.") {
                scriptField("Setup script", text: $setupScript, prompt: "pnpm install")
            }
            SettingsDivider()
            SettingsRow("Run", verbatimDetail: "Runs from the Run button.") {
                scriptField("Run script", text: $runScript, prompt: "pnpm dev --port $PORT")
            }
            SettingsDivider()
            SettingsRow("Archive", verbatimDetail: "Runs before a workspace is removed.") {
                scriptField("Archive script", text: $archiveScript, prompt: "docker compose down")
            }
            SettingsDivider()
            SettingsRow("Run mode", verbatimDetail: "One at a time: Run stops the other workspaces' run scripts first.") {
                runModeMenu
            }
            SettingsDivider()
            note("Scripts run with zsh in the workspace folder. A rocky.json at the root of a workspace replaces these four settings there.")
        }
    }

    private func scriptField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        SettingsTextField(label, text: text, prompt: prompt, isMonospaced: true, isMultiline: true)
            .frame(width: Zoom.shared(280))
    }

    private var runModeMenu: some View {
        MenuButton(id: "run-mode-\(repo.id)", placement: .belowTrailing, width: 240) { isOpen in
            SettingsMenuLabel(title: runMode == .concurrent ? "Concurrent" : "One at a time", isOpen: isOpen)
        } content: {
            MenuItem(title: "Concurrent", detail: "Every workspace can run", isChecked: runMode == .concurrent) {
                runMode = .concurrent
            }
            MenuItem(title: "One at a time", detail: "Run stops the others", isChecked: runMode == .nonconcurrent) {
                runMode = .nonconcurrent
            }
        }
        .help("Whether run scripts of this repository run side by side")
    }

    // MARK: Variables

    private var variablesSection: some View {
        SettingsSection("Variables") {
            ForEach($variables) { $variable in
                variableRow($variable)
                SettingsDivider()
            }
            SettingsRow(
                "Add a variable",
                verbatimDetail: "Every agent, terminal and script of this repository gets these, plus PORT and the ROCKY_* variables. Secrets are stored in the macOS Keychain, not in Rocky's database. Running processes keep the values they started with."
            ) {
                SettingsButton(systemImage: "plus", help: "Add a variable") {
                    variables.append(VariableDraft(name: "", value: "", isSecret: false, savedName: nil, savedAsSecret: false))
                }
            }
        }
    }

    private func variableRow(_ variable: Binding<VariableDraft>) -> some View {
        let draft = variable.wrappedValue
        return HStack(spacing: 8) {
            SettingsTextField("Name", text: variable.name, prompt: "API_URL", isMonospaced: true)
                .frame(width: Zoom.shared(170))
            SettingsTextField(
                "Value",
                text: variable.value,
                prompt: draft.isSecret && draft.savedAsSecret ? "unchanged" : "value",
                isSecure: draft.isSecret
            )
            Toggle(isOn: variable.isSecret) {
                Text("Secret")
            }
            .toggleStyle(.checkbox)
            .font(.rocky(12))
            .foregroundStyle(Theme.textSecondary)
            Button("Remove", systemImage: "xmark") { remove(draft) }
                .buttonStyle(RockyIconButtonStyle(size: 22))
                .font(.rocky(11))
                .help("Remove this variable")
        }
        .padding(.vertical, 8)
    }

    private func remove(_ variable: VariableDraft) {
        if let saved = variable.savedName { removedNames.append(saved) }
        variables.removeAll { $0.id == variable.id }
    }

    // MARK: Claude

    private var claudeSection: some View {
        SettingsSection("Claude") {
            SettingsRow(
                "Claude instance",
                verbatimDetail: "Sets CLAUDE_CONFIG_DIR for Claude Code sessions in this repository. Rocky never inherits it from your shell."
            ) {
                claudeInstanceMenu
            }
        }
    }

    /// The detected instances, plus a stored or picked one no longer detected, so the current choice always shows.
    private var instanceChoices: [String] {
        var choices = instances
        for directory in [repo.claudeConfigDir ?? "", claudeConfigDir] where !directory.isEmpty && !choices.contains(directory) {
            choices.append(directory)
        }
        return choices
    }

    private var claudeInstanceMenu: some View {
        MenuButton(id: "claude-instance-\(repo.id)", placement: .belowTrailing, width: 280) { isOpen in
            SettingsMenuLabel(title: claudeConfigDir.isEmpty ? "Claude default" : Self.homeRelative(claudeConfigDir), isOpen: isOpen)
        } content: {
            MenuItem(title: "Claude default", isChecked: claudeConfigDir.isEmpty) { claudeConfigDir = "" }
            if !instanceChoices.isEmpty {
                MenuDivider()
            }
            ForEach(instanceChoices, id: \.self) { directory in
                MenuItem(title: Self.homeRelative(directory), isChecked: claudeConfigDir == directory) {
                    claudeConfigDir = directory
                }
            }
        }
        .help("The Claude Code instance of this repository")
    }

    /// `~/.claude-work` for a folder in the home folder.
    private static func homeRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: GitHub

    /// ACC-01 and ENV-01: the repository's account, from gh's logins, and its first entry the default.
    private var githubSection: some View {
        SettingsSection("GitHub") {
            SettingsRow(
                "GitHub account",
                verbatimDetail: "Agents, terminals and scripts of this repository get the account's token as GH_TOKEN, and Rocky reads its pull requests with it. The token comes from gh and stays in memory."
            ) {
                githubAccountMenu
            }
            if githubLogin != repo.githubLogin {
                SettingsDivider()
                note("Restart the conversation's agent to use the new account.", color: Theme.attention)
            }
            if let githubProblem {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: githubProblem)
                        .font(.rocky(11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: GitHubAccountError.loginCommand)
                        .font(.rocky(12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var automaticTitle: String {
        automaticLogin.map { "Automatic (\($0))" } ?? "Automatic"
    }

    /// gh's logins, plus a stored one gh no longer lists, so the current choice always shows.
    private var menuLogins: [String] {
        var logins = githubLogins ?? []
        for login in [repo.githubLogin, githubLogin].compactMap({ $0 }) where !logins.contains(login) {
            logins.append(login)
        }
        return logins
    }

    private var githubAccountMenu: some View {
        MenuButton(id: "github-account-\(repo.id)", placement: .belowTrailing, width: 240) { isOpen in
            SettingsMenuLabel(title: githubLogin ?? automaticTitle, isOpen: isOpen, isLoading: githubLogins == nil)
        } content: {
            // Open question 12: the first entry names the login the default resolves to, and stores nil.
            MenuItem(title: automaticTitle, isChecked: githubLogin == nil) { githubLogin = nil }
            if !menuLogins.isEmpty {
                MenuDivider()
            }
            ForEach(menuLogins, id: \.self) { login in
                MenuItem(title: login, isChecked: githubLogin == login) { githubLogin = login }
            }
        }
        .help("The GitHub account of this repository")
    }

    /// Reads gh's accounts again each time the settings open, so a new `gh auth login` shows without relaunching.
    private func loadGitHubAccounts() async {
        do {
            let logins = try await model.githubAccounts.logins(reload: true)
            githubLogins = logins
            githubProblem = logins.isEmpty ? "gh has no GitHub account. Log in with:" : nil
        } catch GitHubAccountError.ghNotFound {
            githubLogins = []
            githubProblem = "The GitHub CLI (gh) is not on your login shell's PATH. Install it, then log in with:"
        } catch {
            githubLogins = []
            githubProblem = "gh could not list your accounts (\(error)). Log in with:"
        }
        automaticLogin = await model.defaultGitHubLogin(for: repo)
    }

    // MARK: Linked files

    /// A row per default with its switch, a row per entry of the user's with its ×, then the add field. The help text
    /// is verbatim: as markdown, the `*` of ".env.*" and ".vscode/*" disappeared.
    private var linkedFilesSection: some View {
        SettingsSection("Linked files") {
            ForEach(LinkedPaths.defaults, id: \.self) { pattern in
                linkedFileRow(pattern, isDefault: true) {
                    Toggle(isOn: defaultIsOn(pattern)) {
                        Text(verbatim: "Link \(pattern)")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                SettingsDivider()
            }
            ForEach(linkedEntries, id: \.self) { entry in
                linkedFileRow(entry, isDefault: false) {
                    Button("Remove", systemImage: "xmark") { linkedEntries.removeAll { $0 == entry } }
                        .buttonStyle(RockyIconButtonStyle(size: 22))
                        .font(.rocky(11))
                        .help(Text(verbatim: "Stop linking \(entry)"))
                }
                SettingsDivider()
            }
            SettingsRow(
                "Add a path",
                verbatimDetail: "New workspaces get these files from the main folder as links. Paths and globs are relative to the repository, such as .venv or .vscode/*."
            ) {
                linkedPathField
            }
        }
    }

    /// A path or glob in the code font, "default" after a default's, and its control.
    private func linkedFileRow(_ path: String, isDefault: Bool, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: path)
                .font(.rocky(12, design: .monospaced))
                .foregroundStyle(isDefault && disabledDefaults.contains(path) ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isDefault {
                Text("default")
                    .font(.rocky(10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.fillSelected, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 8)
    }

    private func defaultIsOn(_ pattern: String) -> Binding<Bool> {
        Binding(
            get: { !disabledDefaults.contains(pattern) },
            set: { isOn in
                if isOn {
                    disabledDefaults.remove(pattern)
                } else {
                    disabledDefaults.insert(pattern)
                }
            }
        )
    }

    private var linkedPathField: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                SettingsTextField("Path or glob", text: $newLinkedPath, prompt: ".venv", isMonospaced: true, onSubmit: { addLinkedPath() })
                    .frame(width: Zoom.shared(200))
                SettingsButton(title: "Add", help: "Link this path into new workspaces") { addLinkedPath() }
            }
            if let linkedPathProblem {
                Text(verbatim: linkedPathProblem.message)
                    .font(.rocky(11))
                    .foregroundStyle(Theme.danger)
            }
        }
        .onChange(of: newLinkedPath) { linkedPathProblem = nil }
    }

    private func addLinkedPath() {
        switch LinkedPaths.validate(newLinkedPath, existing: linkedEntries) {
        case .success(let entry):
            linkedEntries.append(entry)
            newLinkedPath = ""
        case .failure(let problem):
            linkedPathProblem = problem
        }
    }

    // MARK: Save

    private func save() {
        // A path typed but not added yet is added, so Save keeps it; one that is refused keeps the settings open.
        if !newLinkedPath.trimmingCharacters(in: .whitespaces).isEmpty {
            addLinkedPath()
            guard linkedPathProblem == nil else { return }
        }
        model.setScripts(repoId: repo.id, setup: setupScript, run: runScript, archive: archiveScript, runMode: runMode)
        model.setLinkedPaths(repoId: repo.id, LinkedPaths.Setting(disabledDefaults: disabledDefaults, entries: linkedEntries).text)
        model.setGitHubLogin(repoId: repo.id, githubLogin)
        for name in removedNames {
            model.deleteRepoVar(repoId: repo.id, name: name)
        }
        for variable in variables {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let saved = variable.savedName, saved != name {
                model.deleteRepoVar(repoId: repo.id, name: saved)
            }
            let keepsStoredSecret = variable.isSecret && variable.savedAsSecret && variable.savedName == name && variable.value.isEmpty
            if keepsStoredSecret { continue }
            model.setRepoVar(repoId: repo.id, name: name, value: variable.value, isSecret: variable.isSecret)
        }
        Task { await model.setClaudeConfigDir(repoId: repo.id, claudeConfigDir) }
        onClose()
    }
}
