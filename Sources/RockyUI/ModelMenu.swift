import RockyKit
import SwiftUI

/// "Opus 5.5  High ⌄" in the message box. The agent reports its models once its session exists; it starts in the
/// background when the conversation opens, and until then this shows it starting.
struct ModelMenuButton: View {
    let chat: ChatSessionModel

    var body: some View {
        if let model = chat.option(SessionConfigOption.model) {
            MenuButton(id: "model-\(ObjectIdentifier(chat))", placement: .aboveLeading, width: 380) { isOpen in
                label(title: model.currentName, detail: chat.option(SessionConfigOption.effort)?.currentName, isOpen: isOpen)
            } content: {
                ModelMenuContent(chat: chat)
            }
            .disabled(chat.state == .running)
            .help("Model and effort for this conversation")
        } else if chat.state == .starting {
            HStack(spacing: 6) {
                CircularProgress(size: 12)
                Text("Starting \(chat.agent.displayName)…").foregroundStyle(.secondary)
            }
            .font(.rocky(12))
        } else {
            label(title: chat.agent.displayName, detail: nil, isOpen: false)
        }
    }

    private func label(title: String, detail: String?, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            AgentIcon(agent: chat.agent, size: 13)
            Text(title)
            if let detail { Text(detail).foregroundStyle(.secondary) }
            Image(systemName: "chevron.down")
                .font(.rocky(10))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .font(.rocky(12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(isOpen ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// The model picker, like Conductor's: the models with the current one checked, the effort levels as chips, and
/// the fast-mode switch. It reads the chat itself, so it follows the agent's answer to each change. An agent with
/// many models (OpenCode lists every provider's) gets a search field, the models grouped by provider, and a list
/// that scrolls; Return picks the first match.
struct ModelMenuContent: View {
    let chat: ChatSessionModel
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Past this many models the menu searches and scrolls.
    private static let searchThreshold = 8

    var body: some View {
        let model = chat.option(SessionConfigOption.model)
        let effort = chat.option(SessionConfigOption.effort)
        let fast = chat.option(SessionConfigOption.fast)
        if let model {
            MenuSectionTitle(title: "Model")
            if model.choices.count > Self.searchThreshold {
                searchableModels(model, effort: effort)
            } else {
                ForEach(model.choices) { choice in
                    modelRow(choice, title: choice.name, in: model, effort: effort)
                }
            }
        }
        if let effort {
            MenuDivider()
            MenuSectionTitle(title: "Effort")
            EffortChips(option: effort) { value in
                Task { await chat.setOption(effort.id, to: value) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        if let fast {
            MenuDivider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fast")
                    Text("Faster replies on the same model").font(.rocky(10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("Fast", isOn: Binding(
                    get: { fast.current == "on" },
                    set: { on in Task { await chat.setOption(fast.id, to: on ? "on" : "off") } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func searchableModels(_ model: SessionConfigOption, effort: SessionConfigOption?) -> some View {
        let groups = ModelGroup.groups(model.choices, matching: query)
        let matches = groups.flatMap(\.choices)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search \(model.choices.count) models", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = matches.first { pick(first, in: model) }
                    }
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .clickable()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text("No model matches “\(query)”")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(groups) { group in
                            if let provider = group.provider {
                                Text(provider)
                                    .font(.rocky(10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.choices) { choice in
                                modelRow(choice, title: group.provider == nil ? choice.name : ModelGroup.title(of: choice), in: model, effort: effort)
                                    .id(choice.value)
                            }
                        }
                    }
                }
                .frame(height: Zoom.shared(320))
                .onAppear {
                    searchFocused = true
                    proxy.scrollTo(model.current, anchor: .center)
                }
            }
        }
    }

    private func modelRow(_ choice: SessionConfigOption.Choice, title: String, in model: SessionConfigOption, effort: SessionConfigOption?) -> some View {
        PanelRow(isSelected: choice.value == model.current) {
            pick(choice, in: model)
        } content: {
            AgentIcon(agent: chat.agent, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    if choice.value == model.current, let effort {
                        Text(effort.currentName).foregroundStyle(.secondary)
                    }
                }
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.rocky(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if choice.value == model.current {
                Image(systemName: "checkmark").font(.rocky(10, weight: .semibold))
            }
        }
    }

    private func pick(_ choice: SessionConfigOption.Choice, in model: SessionConfigOption) {
        Task { await chat.setOption(model.id, to: choice.value) }
        presenter?.dismiss()
    }
}

/// The effort levels side by side, each name on one line; the current one is lit.
struct EffortChips: View {
    let option: SessionConfigOption
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(option.choices) { choice in
                let isCurrent = choice.value == option.current
                Button {
                    select(choice.value)
                } label: {
                    Text(choice.name)
                        .font(.rocky(10))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .background(isCurrent ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
