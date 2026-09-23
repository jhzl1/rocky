import AppKit
import RockyKit
import SwiftTerm
import SwiftUI

/// Shows one PTY session in a SwiftTerm view. The session outlives the view: switching tab or workspace
/// dismantles the view, and the next one replays the session's buffered output.
struct TerminalHostView: NSViewRepresentable {
    let session: PTYSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        let replay = session.attach(context.coordinator.viewerId) { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        view.feed(byteArray: replay[...])
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

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
