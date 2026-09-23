import AppKit
import RockyKit
import SwiftUI

/// The agent's logo: Claude's starburst in its brand orange, OpenCode's mark in the text color.
/// The SVGs are in Resources/Icons (from Simple Icons, CC0); NSImage draws SVG as vectors.
struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 14

    var body: some View {
        Image(nsImage: Self.image(for: agent))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Self.tint(for: agent))
            .accessibilityLabel(agent.displayName)
    }

    static func tint(for agent: AgentKind) -> Color {
        switch agent {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .opencode: .primary
        }
    }

    private static var images: [AgentKind: NSImage] = [:]

    private static func image(for agent: AgentKind) -> NSImage {
        if let image = images[agent] { return image }
        let url = Bundle.module.url(forResource: agent.rawValue, withExtension: "svg", subdirectory: "Icons")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: agent.displayName)
            ?? NSImage()
        image.isTemplate = true
        images[agent] = image
        return image
    }
}

/// Claude Code | OpenCode, each with its logo. Replaces the plain segmented picker.
struct AgentSwitcher: View {
    @Binding var selection: AgentKind

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentKind.allCases) { agent in
                Button {
                    selection = agent
                } label: {
                    HStack(spacing: 6) {
                        AgentIcon(agent: agent, size: 13)
                        Text(agent.displayName)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        selection == agent ? Color.white.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == agent ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
    }
}
