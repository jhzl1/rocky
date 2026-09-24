import AppKit
import RockyKit
import SwiftUI

/// Rocky's beagle on its rounded white square, the same art as the app icon (scripts/make-icon.swift).
struct RockyLogo: View {
    var size: CGFloat = 64
    private static let image = Bundle.module.url(forResource: "rocky", withExtension: "png", subdirectory: "Icons")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Zoom.shared(size), height: Zoom.shared(size))
                .accessibilityLabel("Rocky")
        }
    }
}

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
            .frame(width: Zoom.shared(size), height: Zoom.shared(size))
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
