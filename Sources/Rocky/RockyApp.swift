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

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                // The login shell runs once per launch (spec Section 1); this re-reads it after you edit ~/.zshrc.
                Button("Refresh Shell Environment") {
                    Task { await model.refreshEnvironment() }
                }
            }
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
