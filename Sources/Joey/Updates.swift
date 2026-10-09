import Combine
import Sparkle
import SwiftUI

/// Mirrors the updater's `canCheckForUpdates` so menu items can disable themselves while a check runs.
final class UpdaterModel: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        Button("Check for Updates…") { model.updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $model.automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: $model.automaticallyDownloads)
                .disabled(!model.automaticallyChecks)
            LabeledContent("Version \(model.currentVersion)") {
                CheckForUpdatesButton(model: model)
            }
        }
    }
}
