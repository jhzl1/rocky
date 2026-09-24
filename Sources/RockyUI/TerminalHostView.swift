import AppKit
import RockyKit
import SwiftTerm
import SwiftUI

/// Shows one PTY session in a SwiftTerm view. The session outlives the view: switching tab or workspace
/// dismantles the view, and the next one replays the session's buffered output.
struct TerminalHostView: NSViewRepresentable {
    let session: PTYSession
    /// `Zoom.scale`: the terminal's 12-point font grows with it.
    var zoom: Double = 1
    /// Names the terminal view, so a key monitor can tell it has the keyboard (CMD-08's embedded terminal).
    var identifier: NSUserInterfaceItemIdentifier?
    /// Takes the keyboard as it appears: the embedded terminal opens to be used at once.
    var focusesOnAppear = false

    /// A Nerd Font when one is installed, because prompts such as powerlevel10k and starship draw their icons with
    /// it (SF Mono shows them as "?"). Otherwise SF Mono.
    private static let nerdFontFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        let preferred = ["MesloLGS Nerd Font Mono", "MesloLGM Nerd Font Mono"].first { families.contains($0) }
        return preferred ?? families.filter { $0.hasSuffix("Nerd Font Mono") }.sorted().first
    }()

    static func font(zoom: Double) -> NSFont {
        let size = 12 * zoom
        if let family = nerdFontFamily, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = Self.font(zoom: zoom)
        // Rocky's background and the system text color, instead of SwiftTerm's black block.
        view.nativeBackgroundColor = Theme.background
        view.nativeForegroundColor = .textColor
        view.caretColor = .controlAccentColor
        view.terminalDelegate = context.coordinator
        let replay = session.attach(context.coordinator.viewerId) { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        view.feed(byteArray: replay[...])
        view.identifier = identifier
        // Once the view is in its window.
        if focusesOnAppear { DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) } }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        let font = Self.font(zoom: zoom)
        if view.font.pointSize != font.pointSize { view.font = font }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.session.detach(coordinator.viewerId)
    }

    @MainActor
    final class Coordinator: NSObject {
        let session: PTYSession
        let viewerId = UUID()

        init(session: PTYSession) {
            self.session = session
        }
    }
}

// SwiftTerm builds in Swift 5 mode, so its delegate is not actor-isolated; TerminalView calls it on the main thread.
extension TerminalHostView.Coordinator: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
