import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TorrentStore()
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    lazy var updaterModel = UpdaterModel(updater: updaterController.updater)

    // Handles .torrent files and videos opened from Finder, and magnet: links from the browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        let videos = urls.filter { $0.isFileURL && Playback.isVideo($0) }
        PlayerLauncher.shared.pending += videos
        store.open(urls.filter { !videos.contains($0) })
    }

    // Keep running (and seeding) after the window is closed; the menu bar item stays available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let recent = WatchHistory.shared.continueWatching(limit: 5)
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Continue Watching"))
            for entry in recent {
                let item = NSMenuItem(title: ReleaseName(entry.url).fullTitle, action: #selector(playFromDock), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.url
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let videos = NSMenuItem(title: "Show Videos", action: #selector(showVideosFromDock), keyEquivalent: "")
        videos.target = self
        menu.addItem(videos)
        return menu
    }

    // The Dock menu has no SwiftUI environment, so the menu bar label opens the windows (see MenuBarLabel).
    @objc private func playFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        PlayerLauncher.shared.pending.append(url)
    }

    @objc private func showVideosFromDock() {
        PlayerLauncher.shared.showVideos = true
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
            CommandGroup(after: .newItem) {
                OpenVideoButton()
            }
            CommandGroup(before: .toolbar) {
                MainTabCommands()
            }
            // Joey has no help book, so the Help menu points at the website and the bundled licenses.
            CommandGroup(replacing: .help) {
                Link("Joey Website", destination: URL(string: "https://joey.kimiyu.ch")!)
                Link("Legal Notice", destination: URL(string: "https://joey.kimiyu.ch/legal")!)
                Divider()
                Button("Acknowledgements") {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        WindowGroup("Player", id: "player", for: URL.self) { $url in
            if let url { PlayerWindow(url: url).environment(delegate.store) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 960, height: 540)
        .restorationBehavior(.disabled)

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
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Defaults.mainTab) private var tab = MainTab.downloads

    var body: some View {
        Group {
            let down = store.totalDownloadRate
            if down >= 1024 {
                Text("↓ \(Format.rate(down))").monospacedDigit()
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        // The menu bar item is always around, so it opens the videos handed to the app from Finder.
        .onChange(of: PlayerLauncher.shared.pending, initial: true) {
            let launcher = PlayerLauncher.shared
            launcher.pending.forEach { openWindow(id: "player", value: $0) }
            if !launcher.pending.isEmpty { launcher.pending = [] }
        }
        .onChange(of: PlayerLauncher.shared.showVideos) {
            guard PlayerLauncher.shared.showVideos else { return }
            PlayerLauncher.shared.showVideos = false
            tab = .videos
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

struct MenuBarContent: View {
    let updaterModel: UpdaterModel
    @Environment(TorrentStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Defaults.mainTab) private var tab = MainTab.downloads

    var body: some View {
        Text("↓ \(Format.rate(store.totalDownloadRate))   ↑ \(Format.rate(store.totalUploadRate))")

        let active = store.torrents.filter { $0.state.isActiveDownload }
        if !active.isEmpty {
            Divider()
            ForEach(active.prefix(8)) { t in
                Text("\(t.name) — \(Format.percent(t.progress))")
            }
        }

        let recent = WatchHistory.shared.continueWatching(limit: 5)
        if !recent.isEmpty {
            Divider()
            Section("Continue Watching") {
                ForEach(recent) { entry in
                    Button(ReleaseName(entry.url).fullTitle) {
                        openWindow(id: "player", value: entry.url)
                        NSApp.activate()
                    }
                }
            }
        }

        Divider()
        Button("Show Joey") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("0")
        Button("Show Videos") {
            tab = .videos
            openWindow(id: "main")
            NSApp.activate()
        }
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
