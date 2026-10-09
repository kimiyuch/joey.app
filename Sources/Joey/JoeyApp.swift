import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TorrentStore()
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    lazy var updaterModel = UpdaterModel(updater: updaterController.updater)

    // Handles .torrent files opened from Finder and magnet: links from the browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        store.open(urls)
    }

    // Keep running (and seeding) after the window is closed; the menu bar item stays available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}

@main
struct JoeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Joey", id: "main") {
            ContentView()
                .environment(delegate.store)
                .frame(minWidth: 760, minHeight: 360)
        }
        .defaultSize(width: 1000, height: 520)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(model: delegate.updaterModel)
            }
        }

        MenuBarExtra {
            MenuBarContent(updaterModel: delegate.updaterModel)
                .environment(delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }

        Settings {
            SettingsView(updaterModel: delegate.updaterModel)
                .environment(delegate.store)
        }
    }
}

struct MenuBarLabel: View {
    let store: TorrentStore

    var body: some View {
        let down = store.totalDownloadRate
        if down >= 1024 {
            Text("↓ \(Format.rate(down))").monospacedDigit()
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

struct MenuBarContent: View {
    let updaterModel: UpdaterModel
    @Environment(TorrentStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("↓ \(Format.rate(store.totalDownloadRate))   ↑ \(Format.rate(store.totalUploadRate))")

        let active = store.torrents.filter { $0.state.isActiveDownload }
        if !active.isEmpty {
            Divider()
            ForEach(active.prefix(8)) { t in
                Text("\(t.name) — \(Format.percent(t.progress))")
            }
        }

        Divider()
        Button("Show Joey") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("0")
        Button("Pause All") { store.pauseAll() }
            .disabled(!store.torrents.contains { !$0.state.isPaused })
        Button("Resume All") { store.resumeAll() }
            .disabled(!store.torrents.contains { $0.state.isPaused })
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        CheckForUpdatesButton(model: updaterModel)
        Button("Quit Joey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
