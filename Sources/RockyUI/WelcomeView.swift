import AppKit
import SwiftUI

/// While no workspace is selected (WEL-01): only Rocky's dog as line art and "Welcome to Rocky", 48 points above the
/// center of the detail area, fading in over 300 ms. It replaced "No workspace selected" with the colored logo and a
/// hint. The top row stays a window-drag area.
struct WelcomeView: View {
    @State private var shown = false

    var body: some View {
        VStack(spacing: 20) {
            RockyDogLine()
                .frame(width: Zoom.shared(200))
            Text("Welcome to Rocky")
                .font(.rocky(15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .offset(y: -48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: WindowMetrics.titleBarHeight)
                .windowDragBackground()
        }
        // Opacity only, so also with Reduce Motion.
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { shown = true } }
    }
}

/// The dog's outline, eyes and nose (`Resources/Icons/rocky-line.svg`, traced from the app icon), drawn as a template
/// in `textTertiary`. NSImage draws the SVG as vectors, so it stays crisp at every zoom. From the Icons folder, as the
/// agents' logos are, rather than an asset catalog.
private struct RockyDogLine: View {
    private static let image: NSImage? = {
        let image = Bundle.module.url(forResource: "rocky-line", withExtension: "svg", subdirectory: "Icons")
            .flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Rocky")
        }
    }
}
