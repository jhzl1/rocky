import RockyKit
import SwiftUI

struct RepoSettingsView: View {
    let model: AppModel
    let repo: Repo
    @Environment(\.dismiss) private var dismiss
    @State private var claudeConfigDir: String
    private let instances = ClaudeInstances.detect(home: FileManager.default.homeDirectoryForCurrentUser)

    init(model: AppModel, repo: Repo) {
        self.model = model
        self.repo = repo
        _claudeConfigDir = State(initialValue: repo.claudeConfigDir ?? "")
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.setClaudeConfigDir(repoId: repo.id, claudeConfigDir)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480)
    }
}
