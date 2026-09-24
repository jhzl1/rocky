import Testing
@testable import RockyKit

struct ModelGroupTests {
    private let choices = [
        SessionConfigOption.Choice(value: "google/gemini-3.6-flash", name: "Google/Gemini 3.6 Flash"),
        SessionConfigOption.Choice(value: "opencode/big-pickle", name: "OpenCode Zen/Big Pickle", detail: "Free"),
        SessionConfigOption.Choice(value: "google/veo-3.1", name: "Google/Veo 3.1"),
        SessionConfigOption.Choice(value: "ollama/qwen3", name: "Ollama (local)/qwen3-coder:30b"),
    ]

    @Test func groupsByProviderOnceInFirstSeenOrder() {
        let groups = ModelGroup.groups(choices, matching: "")
        #expect(groups.map(\.provider) == ["Google", "OpenCode Zen", "Ollama (local)"])
        #expect(groups[0].choices.map(\.value) == ["google/gemini-3.6-flash", "google/veo-3.1"])
        #expect(ModelGroup.title(of: choices[0]) == "Gemini 3.6 Flash")
    }

    @Test func searchesEveryWordInNameValueAndDetailIgnoringCase() {
        #expect(ModelGroup.groups(choices, matching: "google veo").flatMap(\.choices).map(\.value) == ["google/veo-3.1"])
        #expect(ModelGroup.groups(choices, matching: "FREE").flatMap(\.choices).map(\.value) == ["opencode/big-pickle"])
        #expect(ModelGroup.groups(choices, matching: "qwen3").first?.provider == "Ollama (local)")
        #expect(ModelGroup.groups(choices, matching: "claude").isEmpty)
    }

    @Test func aModelWithoutAProviderHasNoGroupTitle() {
        let plain = [SessionConfigOption.Choice(value: "opus", name: "Opus 5.5")]
        #expect(ModelGroup.groups(plain, matching: "").map(\.provider) == [nil])
        #expect(ModelGroup.title(of: plain[0]) == "Opus 5.5")
    }
}
