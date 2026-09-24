import Foundation

/// Models grouped by the provider in their name ("Google/Gemini 3.6 Flash" is Google's), for the model menu's
/// search. Groups keep the order in which the agent lists their first model.
public struct ModelGroup: Identifiable, Equatable, Sendable {
    public let provider: String?
    public let choices: [SessionConfigOption.Choice]
    public var id: String { provider ?? "" }

    public static func provider(of choice: SessionConfigOption.Choice) -> String? {
        guard let slash = choice.name.firstIndex(of: "/") else { return nil }
        return String(choice.name[..<slash])
    }

    /// The name without its provider, which the group's title already shows.
    public static func title(of choice: SessionConfigOption.Choice) -> String {
        guard let slash = choice.name.firstIndex(of: "/") else { return choice.name }
        return String(choice.name[choice.name.index(after: slash)...])
    }

    /// The choices whose name, value or description contain every word of `query`, ignoring case and accents.
    public static func groups(_ choices: [SessionConfigOption.Choice], matching query: String) -> [ModelGroup] {
        let words = query.split(separator: " ").map(String.init)
        let matching = choices.filter { choice in
            let text = [choice.name, choice.value, choice.detail ?? ""].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var order: [String?] = []
        var byProvider: [String: [SessionConfigOption.Choice]] = [:]
        for choice in matching {
            let provider = provider(of: choice)
            let key = provider ?? ""
            if byProvider[key] == nil { order.append(provider) }
            byProvider[key, default: []].append(choice)
        }
        return order.map { ModelGroup(provider: $0, choices: byProvider[$0 ?? ""] ?? []) }
    }
}
