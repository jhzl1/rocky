import RockyKit
import SwiftUI

struct RepoSettingsView: View {
    let model: AppModel
    let repo: Repo
    @Environment(\.dismiss) private var dismiss
    @State private var claudeConfigDir: String
    @State private var setupScript: String
    @State private var runScript: String
    @State private var archiveScript: String
    @State private var runMode: RunScriptMode
    @State private var linkedPaths: String
    @State private var variables: [VariableDraft]
    @State private var removedNames: [String] = []
    private let instances = ClaudeInstances.detect(home: FileManager.default.homeDirectoryForCurrentUser)

    /// One editable variable row. A saved secret's value is never read back into the form: an empty field keeps it.
    struct VariableDraft: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var isSecret: Bool
        let savedName: String?
        let savedAsSecret: Bool
    }

    init(model: AppModel, repo: Repo) {
        self.model = model
        self.repo = repo
        _claudeConfigDir = State(initialValue: repo.claudeConfigDir ?? "")
        _setupScript = State(initialValue: repo.setupScript ?? "")
        _runScript = State(initialValue: repo.runScript ?? "")
        _archiveScript = State(initialValue: repo.archiveScript ?? "")
        _runMode = State(initialValue: RunScriptMode(rawValue: repo.runScriptMode ?? "") ?? .concurrent)
        _linkedPaths = State(initialValue: repo.linkedPaths ?? "")
        _variables = State(initialValue: model.repoVars(repoId: repo.id).map {
            VariableDraft(name: $0.name, value: $0.value ?? "", isSecret: $0.isSecret, savedName: $0.name, savedAsSecret: $0.isSecret)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(repo.name) {
                    Picker("Claude instance", selection: $claudeConfigDir) {
                        Text("Claude default").tag("")
                        ForEach(instances, id: \.self) { Text($0).tag($0) }
                        if !claudeConfigDir.isEmpty && !instances.contains(claudeConfigDir) {
                            Text(claudeConfigDir).tag(claudeConfigDir)
                        }
                    }
                    Text("Sets CLAUDE_CONFIG_DIR for Claude Code sessions in this repo. Rocky never inherits it from your shell.")
                        .font(.rocky(10))
                        .foregroundStyle(.secondary)
                }
                scriptsSection
                linkedFilesSection
                variablesSection
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.clickable()
                Button("Save") { save() }.clickable()
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 640)
    }

    private var scriptsSection: some View {
        Section("Scripts") {
            TextField("Setup", text: $setupScript, prompt: Text("pnpm install"), axis: .vertical)
            TextField("Run", text: $runScript, prompt: Text("pnpm dev --port $PORT"), axis: .vertical)
            TextField("Archive", text: $archiveScript, prompt: Text("docker compose down"), axis: .vertical)
            Picker("Run mode", selection: $runMode) {
                Text("Concurrent: every workspace can run").tag(RunScriptMode.concurrent)
                Text("One at a time: Run stops the others").tag(RunScriptMode.nonconcurrent)
            }
            Text("Scripts run with zsh in the workspace folder: setup once when a workspace is created, run from the Run button, archive before a workspace is removed. A rocky.json at the root of a workspace replaces all three there.")
                .font(.rocky(10))
                .foregroundStyle(.secondary)
        }
    }

    private var linkedFilesSection: some View {
        Section("Linked files") {
            TextField("Paths", text: $linkedPaths, prompt: Text(".venv\n.vscode/*"), axis: .vertical)
                .font(.rocky(13, design: .monospaced))
            Text("Rocky links .env, .env.*, .envrc, .dev.vars and .claude/settings.local.json from the main folder into every new workspace. Add other paths or globs, one per line, such as .venv or .vscode/*.")
                .font(.rocky(10))
                .foregroundStyle(.secondary)
        }
    }

    private var variablesSection: some View {
        Section("Variables") {
            ForEach($variables) { $variable in
                HStack {
                    TextField("Name", text: $variable.name, prompt: Text("API_URL"))
                        .labelsHidden()
                        .font(.rocky(13, design: .monospaced))
                        .frame(width: 170)
                    if variable.isSecret {
                        SecureField("Value", text: $variable.value, prompt: Text(variable.savedAsSecret ? "unchanged" : "value"))
                            .labelsHidden()
                    } else {
                        TextField("Value", text: $variable.value, prompt: Text("value"))
                            .labelsHidden()
                    }
                    Toggle("Secret", isOn: $variable.isSecret)
                        .toggleStyle(.checkbox)
                    Button("Remove", systemImage: "minus.circle") { remove(variable) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .clickable()
                }
            }
            Button("Add Variable", systemImage: "plus") {
                variables.append(VariableDraft(name: "", value: "", isSecret: false, savedName: nil, savedAsSecret: false))
            }
            .clickable()
            Text("Every agent, terminal and script of this repo gets these, plus PORT and the ROCKY_* variables. Secrets are stored in the macOS Keychain, not in Rocky's database. Running processes keep the values they started with.")
                .font(.rocky(10))
                .foregroundStyle(.secondary)
        }
    }

    private func remove(_ variable: VariableDraft) {
        if let saved = variable.savedName { removedNames.append(saved) }
        variables.removeAll { $0.id == variable.id }
    }

    private func save() {
        model.setScripts(repoId: repo.id, setup: setupScript, run: runScript, archive: archiveScript, runMode: runMode)
        model.setLinkedPaths(repoId: repo.id, linkedPaths)
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
        dismiss()
    }
}
