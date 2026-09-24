import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Whether any of the window can be seen: false while it is minimized, hidden, fully covered or on another Space
    /// (`NSWindow.occlusionState`), true until known. Animations and timers run while it is true, with Rocky in front
    /// or not (user decision, 2026-09-24: "Mientras se vea"), so a working agent never looks frozen next to another
    /// app. Whether the user is looking at Rocky stays `appearsActive`.
    @Entry var windowIsVisible = true
}

/// Reports whether its window can be seen, once it is in a window and on each change of the window's occlusion state.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: (any NSObjectProtocol)?

        /// Never takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Moved to another window or out of one: the old window's observer goes either way.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // On the next turn of the main actor, outside the SwiftUI update that put this view in the window.
            Task { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange(window.occlusionState.contains(.visible))
        }
    }
}
