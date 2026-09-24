import AppKit
import RockyKit
import RockyUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed under `swift run` (no bundle); harmless inside Rocky.app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Zoom In is ⌘+, which a US keyboard types with Shift; ⌘= zooms in too, as in browsers.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            MainActor.assumeIsolated { Zoom.shared.zoomIn() }
            return nil
        }
    }

    /// Stops every agent, terminal and script before quitting, so none keeps running (and using energy) after Rocky.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.stopAllProcesses()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RockyApp.makeModel()

    init() {
        // Overlay scroll bars in every scroll view, whatever System Settings or the mouse ask for: only the knob,
        // shown while scrolling, never the gray track. Set in Rocky's own defaults before any view exists.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        // No title bar: the sidebar's top row holds the window buttons and the workspace header sits at the top,
        // like Conductor. "Rocky" stays the window's name in the Window menu.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                ZoomCommands()
            }
            CommandGroup(after: .appSettings) {
                // The login shell runs once per launch (spec Section 1); this re-reads it after you edit ~/.zshrc.
                Button("Refresh Shell Environment") {
                    Task { await model.refreshEnvironment() }
                }
            }
        }
        // Rocky ▸ Settings… (⌘,): the zoom and everything else that applies to the whole app.
        Settings {
            SettingsView(model: model)
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        do {
            let paths = try RockyPaths.standard()
            return AppModel(store: try RockyStore(path: paths.database.path), paths: paths)
        } catch {
            fatalError("Rocky could not open its database: \(error)")
        }
    }
}

/// View ▸ Zoom In, Zoom Out and Actual Size, with the zoom in use.
private struct ZoomCommands: View {
    private var zoom: Zoom { Zoom.shared }

    var body: some View {
        Section {
            Button("Zoom In") { zoom.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoom.canZoomIn)
            Button("Zoom Out") { zoom.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoom.canZoomOut)
            Button("Actual Size") { zoom.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom.isActualSize)
            Button("Zoom: \(Int((zoom.scale * 100).rounded()))%") {}
                .disabled(true)
        }
    }
}
