import RockyKit
import SwiftUI

/// The agent's questions (Claude's AskUserQuestion), above the message box, one question at a time: its options and a
/// box to type another answer, with a step per question at the top, Back and Next, and Submit on the last one.
/// Picking an option of a single-choice question moves on to the next question.
struct QuestionCard: View {
    let agent: AgentKind
    let request: AgentQuestionRequest
    let answer: (AgentQuestionAnswer) -> Void
    @State private var picks: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @State private var index = 0

    private var current: AgentQuestionRequest.Question {
        request.questions[min(index, request.questions.count - 1)]
    }

    private var isLast: Bool {
        index >= request.questions.count - 1
    }

    private func isAnswered(_ question: AgentQuestionRequest.Question) -> Bool {
        !(picks[question.id] ?? []).isEmpty
            || !(other[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAnswer: Bool {
        request.questions.contains(where: isAnswered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                AgentIcon(agent: agent, size: 13)
                Text("\(agent.displayName) asks").foregroundStyle(.secondary)
                Spacer()
                if request.questions.count > 1 {
                    steps
                }
            }
            .font(.rocky(12))
            questionView(current)
                .id(current.id)
                .transition(.opacity)
            HStack {
                Button("Skip") { answer(.skipped) }
                    .buttonStyle(.plain)
                    .clickable()
                    .foregroundStyle(.secondary)
                    .help("Go on without answering")
                Spacer()
                if index > 0 {
                    Button("Back") { index -= 1 }
                        .buttonStyle(.plain)
                        .clickable()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                if isLast {
                    primaryButton("Submit", isEnabled: hasAnswer) { answer(.answered(picks: picks, other: other)) }
                } else {
                    primaryButton("Next", isEnabled: true) { index += 1 }
                }
            }
        }
        .padding(ChatView.boxPadding)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.composerBorder))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    /// One step per question, named by its header: the current one lit, answered ones checked. Click to go back to one.
    private var steps: some View {
        HStack(spacing: 4) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { position, question in
                Button {
                    index = position
                } label: {
                    HStack(spacing: 4) {
                        if isAnswered(question) {
                            Image(systemName: "checkmark").font(.rocky(10, weight: .bold))
                        }
                        Text(question.header.flatMap { $0.isEmpty ? nil : $0 } ?? "Question \(position + 1)")
                    }
                    .font(.rocky(10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(position == index ? Color.primary : Color.secondary)
                    .background(Color.white.opacity(position == index ? 0.12 : 0.04), in: Capsule())
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
    }

    private func primaryButton(_ title: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.rocky(12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(isEnabled ? Color.black : Color.secondary)
                .background(isEnabled ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .clickable()
        .disabled(!isEnabled)
    }

    private func questionView(_ question: AgentQuestionRequest.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let header = question.header, !header.isEmpty {
                    DetailBadge(text: header.uppercased(), monospaced: true)
                }
                Text(question.text)
                    .font(.rocky(14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            ForEach(question.options) { option in
                let isPicked = (picks[question.id] ?? []).contains(option.label)
                PanelRow(isSelected: isPicked) {
                    toggle(option.label, in: question)
                } content: {
                    Image(systemName: symbol(isPicked: isPicked, multiple: question.allowsMultiple))
                        .foregroundStyle(isPicked ? Color.primary : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.rocky(10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if question.otherFieldId != nil {
                TextField("Other answer", text: Binding(
                    get: { other[question.id] ?? "" },
                    set: { other[question.id] = $0 }
                ))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.08)))
                .padding(.top, 2)
            }
        }
        .font(.rocky(12))
    }

    private func toggle(_ label: String, in question: AgentQuestionRequest.Question) {
        var chosen = picks[question.id] ?? []
        if question.allowsMultiple {
            if let position = chosen.firstIndex(of: label) { chosen.remove(at: position) } else { chosen.append(label) }
        } else {
            chosen = chosen == [label] ? [] : [label]
        }
        picks[question.id] = chosen
        // A single choice answers the question: go on to the next one.
        if !question.allowsMultiple, !chosen.isEmpty, !isLast {
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.15)) { index += 1 }
            }
        }
    }

    private func symbol(isPicked: Bool, multiple: Bool) -> String {
        switch (multiple, isPicked) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }
}
