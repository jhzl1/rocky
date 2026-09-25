import RockyKit
import SwiftUI

/// "Opus 5.5  High ⌄" in the message box. The agent reports its models once its session exists; it starts in the
/// background when the conversation opens, and until then the button is already a menu, with the spinner in place of
/// the agent's logo and no text (`AGM-05`). Disabled while a turn runs (`AGM-06`).
struct ModelMenuButton: View {
    let model: AppModel
    let workspaceId: String
    let conversationId: String
    let chat: ChatSessionModel

    /// The menu is keyed by the conversation, not by its chat: an agent switch builds a new chat, and the open menu
    /// stays (`AGM-02`, M2.8 Decision 4).
    static func menuId(conversationId: String) -> String {
        "model-\(conversationId)"
    }

    private var isStarting: Bool {
        chat.state == .idle || chat.state == .starting
    }

    var body: some View {
        MenuButton(
            id: Self.menuId(conversationId: conversationId),
            placement: .aboveLeading,
            width: ModelMenuContent.width,
            padded: false
        ) { isOpen in
            label(isOpen: isOpen)
        } content: {
            ModelMenuContent(model: model, workspaceId: workspaceId, conversationId: conversationId)
        }
        .disabled(chat.state == .running)
        .help(isStarting ? "Starting \(chat.agent.displayName)" : "Agent, model and effort for this conversation")
        .accessibilityLabel(isStarting ? "Starting \(chat.agent.displayName)" : accessibilityTitle)
    }

    private var accessibilityTitle: String {
        guard let model = chat.option(SessionConfigOption.model) else { return chat.agent.displayName }
        return [model.currentName, ModelMenuContent.effortLabel(chat.option(SessionConfigOption.effort))]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func label(isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            if isStarting {
                // AGM-05: only the spinner, no "Starting…" text anywhere (user decision, 2026-09-23).
                CircularProgress(size: 12)
            } else {
                AgentIcon(agent: chat.agent, size: 13)
                if let model = chat.option(SessionConfigOption.model) {
                    Text(model.currentName)
                    // AGM-07: "Opus 5.5 High", or "Opus 5.5" at the agent's "Default" (M2.8 Decision 9).
                    if let effort = ModelMenuContent.effortLabel(chat.option(SessionConfigOption.effort)) {
                        Text(effort).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text(chat.agent.displayName)
                }
            }
            Image(systemName: "chevron.down")
                .font(.rocky(10))
                .foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .font(.rocky(12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(isOpen ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// The model menu, like Conductor's, with the agents in a rail at its left (`AGM-01`, user decision, 2026-09-23,
/// option B). The body shows the agent picked in the rail: the conversation's own agent shows its models with the
/// current one checked, the effort levels as chips and the fast-mode switch; another agent shows the models it last
/// reported (`AGM-04`), and picking one switches an empty conversation to that agent or opens a new conversation
/// (`AGM-02`, `AGM-03`). A pick keeps the menu open, except when another tab takes over (`AGM-07`).
///
/// `MenuButton` captures this view when the menu opens, and an agent switch replaces the conversation's chat while it
/// is open: it holds the conversation's id, never its chat, and reads `AppModel.chat(conversationId:)` on every body
/// (M2.8 Decision 4). An agent with many models (OpenCode lists every provider's) gets a search field, the models
/// grouped by provider, and a list that scrolls; Return picks the first match.
struct ModelMenuContent: View {
    let model: AppModel
    let workspaceId: String
    let conversationId: String
    @Environment(MenuPresenter.self) private var presenter: MenuPresenter?
    /// The agent the rail shows; nil is the conversation's own, which the menu opens on (`AGM-01`).
    @State private var shownAgent: AgentKind?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var railFocused: Bool
    /// `AGM-07`: the Effort row drawn, which follows the session's `effort` option. Options change in RockyKit, where
    /// the view cannot wrap them in an animation; this copy changes in one here, so the whole menu, the panel's height
    /// and place included, moves with the row.
    @State private var shownEffort: SessionConfigOption?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, workspaceId: String, conversationId: String) {
        self.model = model
        self.workspaceId = workspaceId
        self.conversationId = conversationId
        // The menu opens with the Effort row its chat has, at its full height, with no motion.
        _shownEffort = State(initialValue: model.chat(conversationId: conversationId).flatMap(Self.liveEffort))
    }

    /// Today's 380 of models, with the 48 of the rail (`AGM-01`).
    static let width: CGFloat = railWidth + bodyWidth
    static let railWidth: CGFloat = 48
    static let bodyWidth: CGFloat = 380
    /// Past this many models the menu searches and scrolls.
    private static let searchThreshold = 8

    /// `AGM-07`: the effort after the model's name, in the button and on the selected row, except the agent's
    /// "Default", which is left out ("GPT-5.5", not "GPT-5.5 Default"). The chip keeps its name.
    static func effortLabel(_ effort: SessionConfigOption?) -> String? {
        guard let effort, effort.current.lowercased() != "default", effort.currentName.lowercased() != "default" else {
            return nil
        }
        return effort.currentName
    }

    /// The session's effort levels once the agent is ready; none while it starts, since a new session's come with its
    /// options (`AGM-05`).
    private static func liveEffort(_ chat: ChatSessionModel) -> SessionConfigOption? {
        chat.state == .idle || chat.state == .starting ? nil : chat.option(SessionConfigOption.effort)
    }

    var body: some View {
        if let chat = model.chat(conversationId: conversationId) {
            let shown = shownAgent ?? chat.agent
            HStack(alignment: .top, spacing: 0) {
                rail(current: chat.agent, shown: shown)
                VStack(alignment: .leading, spacing: 0) {
                    agentBody(shown, chat: chat)
                }
                .padding(6)
                .frame(width: Zoom.shared(Self.bodyWidth), alignment: .leading)
            }
            // The rail's fill and its hairline take the menu's full height, however tall the body is.
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    Theme.agentRail
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                .frame(width: Zoom.shared(Self.railWidth))
            }
            .onChange(of: Self.liveEffort(chat)) { old, new in
                withAnimation(effortAnimation(from: old, to: new)) { shownEffort = new }
            }
        }
    }

    // MARK: Effort (AGM-07)

    /// The model's levels appear (the last model had none, or the session just reported them), go (the new model has
    /// none), change (both have levels) or move (another level picked). None with Reduce Motion: the row then only
    /// fades in, and its chips' labels cross-fade, on their own animations.
    private func effortAnimation(from old: SessionConfigOption?, to new: SessionConfigOption?) -> Animation? {
        guard !reduceMotion else { return nil }
        switch (old, new) {
        case (nil, .some): return Theme.Motion.effortAppear
        case (.some, nil): return Theme.Motion.effortDisappear
        default: return Theme.Motion.slide
        }
    }

    /// Appears growing from nothing, fading in and rising 4 points, as the menu grows upwards from its button; goes
    /// shrinking and fading. With Reduce Motion it fades in, 150 ms, and goes at once.
    private var effortTransition: AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(Theme.Motion.crossFade), removal: .identity)
        }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: Zoom.shared(4))), removal: .opacity)
    }

    // MARK: The rail (AGM-01)

    /// One 34-point item per agent, 6 apart from the top: only its logo. A vertical tab list, read by name; ↑ and ↓
    /// move between agents while it has the keyboard, which a click gives it. Selecting an item only changes what the
    /// body shows: nothing switches until a model is picked.
    private func rail(current: AgentKind, shown: AgentKind) -> some View {
        VStack(spacing: Zoom.shared(6)) {
            ForEach(AgentKind.allCases) { agent in
                let name = agent == current ? "\(agent.displayName) (current)" : agent.displayName
                Button {
                    show(agent)
                    railFocused = true
                } label: {
                    AgentIcon(agent: agent, size: 22)
                }
                .buttonStyle(AgentRailItemStyle(isSelected: agent == shown, isCurrent: agent == current))
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(agent == shown ? .isSelected : [])
            }
        }
        .padding(.vertical, Zoom.shared(10))
        .frame(width: Zoom.shared(Self.railWidth))
        .focusable()
        .focused($railFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1, from: shown) }
        .onKeyPress(.downArrow) { step(1, from: shown) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent")
    }

    private func show(_ agent: AgentKind) {
        guard agent != shownAgent else { return }
        shownAgent = agent
        query = ""
    }

    private func step(_ offset: Int, from shown: AgentKind) -> KeyPress.Result {
        let agents = AgentKind.allCases
        guard let index = agents.firstIndex(of: shown) else { return .ignored }
        let next = index + offset
        guard agents.indices.contains(next) else { return .handled }
        show(agents[next])
        return .handled
    }

    // MARK: The body

    /// The title row, then the models: the conversation's own agent's from its session, or, while it starts, the ones
    /// it last reported, with the pick waiting checked (`AGM-05`); another agent's from the catalog (`AGM-04`).
    @ViewBuilder
    private func agentBody(_ agent: AgentKind, chat: ChatSessionModel) -> some View {
        let isCurrent = agent == chat.agent
        let isStarting = chat.state == .idle || chat.state == .starting
        let live = isCurrent && !isStarting ? chat.option(SessionConfigOption.model) : nil
        let known = isCurrent ? (chat.option(SessionConfigOption.model)?.choices ?? catalog(agent)) : catalog(agent)
        if let live {
            titleRow(agent, count: live.choices.count, isStarting: false)
            currentContent(live, chat: chat)
        } else if isCurrent, isStarting {
            if let known, !known.isEmpty {
                titleRow(agent, count: nil, isStarting: true)
                // It neither shrinks nor jumps while the agent starts: its last list, the pick waiting checked.
                models(known, selected: chat.pendingModel?.value ?? chat.option(SessionConfigOption.model)?.current, effort: nil) {
                    pick($0.value, of: agent, chat: chat)
                }
            } else {
                // AGM-05: nothing in the catalog either. One spinner, the body's, not a second one in the title row
                // (user decision, 2026-09-25: "con uno solo es suficiente").
                titleRow(agent, count: nil, isStarting: false)
                loadingList
            }
        } else if let known, !known.isEmpty {
            titleRow(agent, count: known.count, isStarting: false)
            // No effort or Fast: an agent reports them only for its current model, in its session (AGM-07).
            models(known, selected: nil, effort: nil) { pick($0.value, of: agent, chat: chat) }
        } else {
            titleRow(agent, count: nil, isStarting: false)
            noList(agent)
        }
    }

    /// A list on its way: the one spinner, centered in the body.
    private var loadingList: some View {
        CircularProgress(size: 14)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }

    private func catalog(_ agent: AgentKind) -> [SessionConfigOption.Choice]? {
        model.knownModels(agent: agent, workspaceId: workspaceId)
    }

    /// The agent's name, 13 semibold, then "42 models", or the spinner while it starts (`AGM-05`).
    private func titleRow(_ agent: AgentKind, count: Int?, isStarting: Bool) -> some View {
        HStack(spacing: 8) {
            Text(agent.displayName).font(.rocky(13, weight: .semibold))
            if isStarting {
                CircularProgress(size: 12, tint: Theme.textSecondary)
            } else if let count {
                Text(count == 1 ? "1 model" : "\(count) models")
                    .font(.rocky(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// `AGM-04`: an agent that never reported its models here loads them by itself, in the background, with no button
    /// (user decision, 2026-09-25: "la idea es que cargue solo"): the spinner until the catalog has them, or why it
    /// could not; showing the agent again tries again.
    @ViewBuilder
    private func noList(_ agent: AgentKind) -> some View {
        Group {
            if let failure = model.modelsFailure(agent: agent, workspaceId: workspaceId) {
                Text("Couldn't load \(agent.displayName)'s models: \(failure)")
                    .font(.rocky(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
            } else {
                loadingList
            }
        }
        .task(id: agent) { model.loadModelsIfNeeded(agent: agent, workspaceId: workspaceId) }
    }

    /// The conversation's own agent, its session running: its models, the selected model's effort levels, exactly the
    /// session's, in the agent's order (`AGM-07`), and the fast-mode switch when it offers one.
    @ViewBuilder
    private func currentContent(_ option: SessionConfigOption, chat: ChatSessionModel) -> some View {
        let fast = chat.option(SessionConfigOption.fast)
        models(option.choices, selected: option.current, effort: chat.option(SessionConfigOption.effort)) {
            pick($0.value, of: chat.agent, chat: chat)
        }
        if let effort = shownEffort {
            // The divider and the title come and go with the chips.
            VStack(alignment: .leading, spacing: 0) {
                MenuDivider()
                MenuSectionTitle(title: "Effort")
                EffortChips(option: effort) { value in
                    Task { await chat.setOption(effort.id, to: value) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .transition(effortTransition)
        }
        if let fast {
            MenuDivider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fast")
                    Text("Faster replies on the same model").font(.rocky(10)).foregroundStyle(Theme.textTertiary)
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

    /// The rows, or past `searchThreshold` the search field and the rows grouped by provider in a list that scrolls.
    @ViewBuilder
    private func models(
        _ choices: [SessionConfigOption.Choice],
        selected: String?,
        effort: SessionConfigOption?,
        onPick: @escaping (SessionConfigOption.Choice) -> Void
    ) -> some View {
        if choices.count > Self.searchThreshold {
            searchableModels(choices, selected: selected, effort: effort, onPick: onPick)
        } else {
            ForEach(choices) { choice in
                modelRow(choice, title: choice.name, selected: selected, effort: effort, onPick: onPick)
            }
        }
    }

    private func searchableModels(
        _ choices: [SessionConfigOption.Choice],
        selected: String?,
        effort: SessionConfigOption?,
        onPick: @escaping (SessionConfigOption.Choice) -> Void
    ) -> some View {
        let groups = ModelGroup.groups(choices, matching: query)
        let matches = groups.flatMap(\.choices)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search \(choices.count) models", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = matches.first { onPick(first) }
                    }
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .clickable()
                        .foregroundStyle(Theme.textTertiary)
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
                                .foregroundStyle(Theme.textSecondary)
                                .padding(10)
                        }
                        ForEach(groups) { group in
                            if let provider = group.provider {
                                Text(provider)
                                    .font(.rocky(10, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.choices) { choice in
                                let title = group.provider == nil ? choice.name : ModelGroup.title(of: choice)
                                modelRow(choice, title: title, selected: selected, effort: effort, onPick: onPick)
                                    .id(choice.value)
                            }
                        }
                    }
                }
                .frame(height: Zoom.shared(320))
                .onAppear {
                    // The rail keeps the keyboard it was given, so ↑ and ↓ go on moving between agents.
                    if !railFocused { searchFocused = true }
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
    }

    /// A model: its name, the effort after it when it is the selected one, and its description. No logo: the rail and
    /// the title say whose it is (`AGM-01`).
    private func modelRow(
        _ choice: SessionConfigOption.Choice,
        title: String,
        selected: String?,
        effort: SessionConfigOption?,
        onPick: @escaping (SessionConfigOption.Choice) -> Void
    ) -> some View {
        let isSelected = choice.value == selected
        return PanelRow(isSelected: isSelected) {
            onPick(choice)
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    if isSelected, let label = Self.effortLabel(effort) {
                        Text(label).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.rocky(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark").font(.rocky(10, weight: .semibold))
            }
        }
    }

    /// A pick keeps the menu open (`AGM-07`, M2.8 Decision 6): the effort is one click away, and a switch in place
    /// shows its agent starting here. Another agent's pick takes the message box's draft along (`AGM-02`, `AGM-03`);
    /// when a new tab takes over, the menu closes and that tab's message box has the keyboard.
    private func pick(_ value: String?, of agent: AgentKind, chat: ChatSessionModel) {
        let draft = agent == chat.agent ? nil : ConversationComposers.controller(conversationId: conversationId)?.draft
        let model = self.model
        let conversationId = self.conversationId
        let presenter = self.presenter
        Task {
            let result = await model.pickModel(conversationId: conversationId, agent: agent, model: value, draft: draft)
            if result == .openedConversation { presenter?.dismiss() }
        }
    }
}

/// `AGM-01`'s rail item: 34 × 34, radius 8; the logo at 60 % unselected, 85 % on `fillHover` while hovered, and at full
/// opacity on `fillSelected` with a 3-point `textPrimary` bar at the rail's left edge while selected. The conversation's
/// agent carries a 6-point `success` dot at its logo's bottom right, ringed 2 points in `panel`. The requirement's own
/// values, where `RockyIconButtonStyle` would light a hovered item with `fillIconHover`.
private struct AgentRailItemStyle: ButtonStyle {
    let isSelected: Bool
    let isCurrent: Bool

    func makeBody(configuration: Configuration) -> some View {
        AgentRailItem(configuration: configuration, isSelected: isSelected, isCurrent: isCurrent)
    }

    private struct AgentRailItem: View {
        let configuration: Configuration
        let isSelected: Bool
        let isCurrent: Bool
        @State private var hovering = false

        private static let size: CGFloat = 34
        /// (48 − 34) / 2: the bar sits on the rail's left edge.
        private static let barOffset: CGFloat = 7

        var body: some View {
            configuration.label
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Circle()
                            .fill(Theme.success)
                            .frame(width: Zoom.shared(6), height: Zoom.shared(6))
                            .padding(Zoom.shared(2))
                            .background(Circle().fill(Theme.panel))
                            // Centered on the logo's corner: the dot's edge 3 points inside the item's.
                            .offset(x: Zoom.shared(5), y: Zoom.shared(5))
                    }
                }
                .opacity(isSelected ? 1 : hovering ? 0.85 : 0.6)
                .frame(width: Zoom.shared(Self.size), height: Zoom.shared(Self.size))
                .background(
                    isSelected ? Theme.fillSelected : hovering ? Theme.fillHover : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.textPrimary)
                            .frame(width: Zoom.shared(3), height: Zoom.shared(Self.size - 16))
                            .offset(x: -Zoom.shared(Self.barOffset))
                    }
                }
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
                .clickable()
        }
    }
}

/// The effort levels side by side, as equal-width chips, each name on one line; the current one is lit (`AGM-07`).
/// Chips are kept by position, so another model's levels change their labels in place, which cross-fade, while the
/// lit fill slides to the new level, as it does to a picked one. With Reduce Motion the labels still fade, and the
/// fill moves at once.
struct EffortChips: View {
    let option: SessionConfigOption
    let select: (String) -> Void
    @Namespace private var fillSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(option.choices.enumerated()), id: \.offset) { _, choice in
                chip(choice, isCurrent: choice.value == option.current)
            }
        }
        .padding(2)
        .background(Theme.fillControl, in: RoundedRectangle(cornerRadius: 7))
    }

    private func chip(_ choice: SessionConfigOption.Choice, isCurrent: Bool) -> some View {
        Button {
            select(choice.value)
        } label: {
            Text(choice.name)
                .font(.rocky(12))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
                .animation(Theme.Motion.crossFade, value: choice.name)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: Zoom.shared(24))
                .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textSecondary)
                .background {
                    if isCurrent { fill }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        // A level the last model did not have fades in, and one it had fades out.
        .transition(.opacity.animation(Theme.Motion.crossFade))
    }

    /// One fill, matched across the chips, so it slides from the level it left to the one lit now.
    @ViewBuilder
    private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: 5).fill(Theme.fillSelected)
        if reduceMotion {
            shape
        } else {
            shape.matchedGeometryEffect(id: "selected", in: fillSpace)
        }
    }
}
