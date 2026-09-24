import Foundation

/// Questions the agent asks the user in the middle of a turn. Claude's adapter turns its AskUserQuestion tool into
/// an ACP form elicitation (`elicitation/create`), and only when the client says it can show forms
/// (`clientCapabilities.elicitation.form`); otherwise it takes the tool away and the agent says the session is not
/// interactive. Each question is a form field `question_<n>` with its options, followed by an optional free-text
/// field `question_<n>_custom` ("Other").
public struct AgentQuestionRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let label: String
        public let detail: String?
        public var id: String { label }
    }

    public struct Question: Sendable, Equatable, Identifiable {
        /// The form field that carries the answer.
        public let id: String
        /// A short tag, such as "Auth method".
        public let header: String?
        public let text: String
        public let options: [Option]
        public let allowsMultiple: Bool
        /// The field for a typed answer, when the agent offers one.
        public let otherFieldId: String?
    }

    public let message: String
    public let questions: [Question]
}

public enum AgentQuestionAnswer: Sendable, Equatable {
    /// The chosen option labels and the typed answers, both by question id.
    case answered(picks: [String: [String]], other: [String: String])
    /// The user skipped: the agent is told there is no answer and goes on.
    case skipped
    /// The turn was stopped: the tool call is aborted.
    case cancelled
}

extension ACPProtocol {
    public static let questionMethod = "elicitation/create"

    /// Reads an `elicitation/create` form; nil when it holds no question Rocky can show.
    public static func questionRequest(from params: JSONValue) -> AgentQuestionRequest? {
        guard (params["mode"]?.stringValue ?? "form") == "form",
              case .object(let fields)? = params["requestedSchema"]?["properties"] else { return nil }
        let message = params["message"]?.stringValue ?? ""
        let ids = fields.keys.filter { !$0.hasSuffix("_custom") }.sorted(by: fieldOrder)
        let questions = ids.compactMap { id -> AgentQuestionRequest.Question? in
            guard let field = fields[id] else { return nil }
            let allowsMultiple = field["type"]?.stringValue == "array"
            let choices = (allowsMultiple ? field["items"]?["anyOf"] : field["oneOf"])?.arrayValue ?? []
            var options = choices.compactMap { choice -> AgentQuestionRequest.Option? in
                guard let label = choice["const"]?.stringValue else { return nil }
                return AgentQuestionRequest.Option(label: label, detail: choice["description"]?.stringValue)
            }
            // A plain JSON Schema enum has no titles or descriptions.
            if options.isEmpty, let values = (allowsMultiple ? field["items"]?["enum"] : field["enum"])?.arrayValue {
                options = values.compactMap { $0.stringValue.map { AgentQuestionRequest.Option(label: $0, detail: nil) } }
            }
            // One question is asked in `message`; with several, each field carries its own.
            let text = field["description"]?.stringValue ?? (ids.count == 1 ? message : field["title"]?.stringValue ?? id)
            let otherId = "\(id)_custom"
            return AgentQuestionRequest.Question(
                id: id,
                header: field["title"]?.stringValue,
                text: text,
                options: options,
                allowsMultiple: allowsMultiple,
                otherFieldId: fields[otherId] == nil ? nil : otherId
            )
        }
        guard !questions.isEmpty else { return nil }
        return AgentQuestionRequest(message: message, questions: questions)
    }

    /// "question_2" before "question_10".
    private static func fieldOrder(_ lhs: String, _ rhs: String) -> Bool {
        func index(_ id: String) -> Int? { id.split(separator: "_").last.flatMap { Int($0) } }
        if let left = index(lhs), let right = index(rhs), left != right { return left < right }
        return lhs < rhs
    }

    public static func questionResponse(_ answer: AgentQuestionAnswer, for request: AgentQuestionRequest) -> JSONValue {
        switch answer {
        case .skipped:
            return ["action": "decline"]
        case .cancelled:
            return ["action": "cancel"]
        case let .answered(picks, other):
            var content: [String: JSONValue] = [:]
            for question in request.questions {
                let chosen = picks[question.id] ?? []
                if question.allowsMultiple {
                    content[question.id] = .array(chosen.map { .string($0) })
                } else if let first = chosen.first {
                    content[question.id] = .string(first)
                }
                let typed = other[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let otherId = question.otherFieldId, !typed.isEmpty {
                    content[otherId] = .string(typed)
                }
            }
            return ["action": "accept", "content": .object(content)]
        }
    }
}
