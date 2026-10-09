import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TorrentStore.self) private var store
    @State private var selection = Set<String>()
    @AppStorage("showInspector") private var showInspector = false
    @State private var showImporter = false
    @State private var showMagnetSheet = false
    @State private var pendingRemoval = Set<String>()
    @SceneStorage("torrentColumns") private var columnCustomization = TableColumnCustomization<TorrentItem>()

    private var selectedTorrents: [TorrentItem] { store.torrents.filter { selection.contains($0.id) } }

    var body: some View {
        @Bindable var store = store

        Table(store.torrents, selection: $selection, columnCustomization: $columnCustomization) {
            TableColumn("Name") { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).lineLimit(1).truncationMode(.middle)
                    if !t.error.isEmpty {
                        Text(t.error).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .help(t.name)
            }
            .width(min: 120, ideal: 300)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Size") { t in
                Text(t.hasMetadata ? Format.bytes(t.totalWanted) : "–").monospacedDigit()
            }
            .width(min: 55, ideal: 75)
            .customizationID("size")
            TableColumn("Progress") { t in
                HStack(spacing: 6) {
                    ProgressView(value: t.progress).tint(t.state.tint)
                    Text(Format.percent(t.progress))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .width(min: 100, ideal: 160)
            .customizationID("progress")
            TableColumn("Status") { t in Text(t.state.label).foregroundStyle(t.state.tint).lineLimit(1) }
                .width(min: 60, ideal: 100)
                .customizationID("status")
            TableColumn("Speed") { t in Text(speed(t)).monospacedDigit().lineLimit(1) }
                .width(min: 70, ideal: 150)
                .customizationID("speed")
            TableColumn("Peers") { t in Text("\(t.seeds)/\(t.peers)").monospacedDigit() }
                .width(min: 36, ideal: 50)
                .customizationID("peers")
            TableColumn("ETA") { t in Text(Format.eta(t.eta)).monospacedDigit().lineLimit(1) }
                .width(min: 40, ideal: 65)
                .customizationID("eta")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Resume") { store.resume(ids) }
                Button("Pause") { store.pause(ids) }
                Button("Verify Data") { store.recheck(ids) }
                Toggle("Download in Order", isOn: Binding(
                    get: { store.torrents.filter { ids.contains($0.id) }.allSatisfy(\.sequential) },
                    set: { store.setSequential(ids, $0) }
                ))
                Divider()
                Button("Show in Finder") { store.reveal(ids) }
                Divider()
                Button("Remove…") { pendingRemoval = ids }
            }
        } primaryAction: { ids in
            store.reveal(ids)
        }
        .onDeleteCommand { if !selection.isEmpty { pendingRemoval = selection } }
        .overlay {
            if store.torrents.isEmpty {
                ContentUnavailableView {
                    Label("No Torrents", systemImage: "arrow.down.circle")
                } description: {
                    Text("Drop a .torrent file here, or add a magnet link.")
                } actions: {
                    Button("Add Magnet Link…") { showMagnetSheet = true }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let torrents = urls.filter { $0.pathExtension.lowercased() == "torrent" || $0.scheme == "magnet" }
            store.open(torrents)
            return !torrents.isEmpty
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if selectedTorrents.count == 1, let torrent = selectedTorrents.first {
                    InspectorView(torrent: torrent)
                } else {
                    ContentUnavailableView(
                        selection.isEmpty ? "No Selection" : "\(selection.count) Torrents Selected",
                        systemImage: "info.circle"
                    )
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .toolbar { toolbar }
        .navigationSubtitle("↓ \(Format.rate(store.totalDownloadRate))   ↑ \(Format.rate(store.totalUploadRate))")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { store.open(urls) }
        }
        .sheet(isPresented: $showMagnetSheet) { MagnetSheet() }
        .confirmationDialog(
            pendingRemoval.count == 1 ? "Remove this torrent?" : "Remove \(pendingRemoval.count) torrents?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Remove") { remove(deleteFiles: false) }
            Button("Remove and Delete Data", role: .destructive) { remove(deleteFiles: true) }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Torrent File", systemImage: "doc.badge.plus") { showImporter = true }
                .keyboardShortcut("o")
            Button("Add Magnet Link", systemImage: "link.badge.plus") { showMagnetSheet = true }
                .keyboardShortcut("u")
        }
        ToolbarItemGroup {
            Button("Resume", systemImage: "play.fill") { store.resume(selection) }
                .disabled(!selectedTorrents.contains { $0.state.isPaused || $0.state == .queued })
            Button("Pause", systemImage: "pause.fill") { store.pause(selection) }
                .disabled(!selectedTorrents.contains { !$0.state.isPaused })
            Button("Remove", systemImage: "trash") { pendingRemoval = selection }
                .disabled(selection.isEmpty)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
        }
        ToolbarItem {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        }
    }

    /// Only shows the directions that are actually moving, e.g. "↓ 1.2 MB/s  ↑ 40 KB/s".
    private func speed(_ t: TorrentItem) -> String {
        var parts: [String] = []
        if t.downloadRate >= 1024 { parts.append("↓ \(Format.rate(t.downloadRate))") }
        if t.uploadRate >= 1024 { parts.append("↑ \(Format.rate(t.uploadRate))") }
        return parts.isEmpty ? "–" : parts.joined(separator: "  ")
    }

    private func remove(deleteFiles: Bool) {
        store.remove(pendingRemoval, deleteFiles: deleteFiles)
        selection.subtract(pendingRemoval)
        pendingRemoval = []
    }
}

extension TorrentState {
    var tint: Color {
        switch self {
        case .downloading, .metadata: .blue
        case .seeding, .finished: .green
        case .error: .red
        case .checking: .orange
        case .paused, .queued: .secondary
        }
    }
}

struct InspectorView: View {
    @Environment(TorrentStore.self) private var store
    let torrent: TorrentItem
    @State private var files: [TorrentFile] = []

    var body: some View {
        List {
            Section {
                Text(torrent.name).font(.headline).textSelection(.enabled)
                LabeledContent("Status", value: torrent.state.label)
                LabeledContent("Downloaded", value: "\(Format.bytes(torrent.totalDone)) of \(Format.bytes(torrent.totalWanted))")
                LabeledContent("Uploaded", value: Format.bytes(torrent.uploaded))
                LabeledContent("Ratio", value: torrent.ratio.formatted(.number.precision(.fractionLength(2))))
                LabeledContent("Peers", value: "\(torrent.peers) (\(torrent.seeds) seeds)")
                if torrent.seedingTime > 0 {
                    LabeledContent("Seeding for", value: Format.eta(torrent.seedingTime))
                }
                Toggle("Download in order", isOn: Binding(
                    get: { torrent.sequential },
                    set: { store.setSequential([torrent.id], $0) }
                ))
                .help("Fetch pieces from start to end so you can watch a video while it downloads.")
                LabeledContent("Location") {
                    Button(torrent.savePath) { store.reveal([torrent.id]) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                }
                if !torrent.error.isEmpty {
                    Text(torrent.error).foregroundStyle(.red)
                }
            }
            Section("Files") {
                if files.isEmpty {
                    Text(torrent.hasMetadata ? "No files" : "Waiting for metadata…").foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    Toggle(isOn: Binding(
                        get: { file.priority > 0 },
                        set: { store.setFile(file.id, of: torrent.id, wanted: $0); reloadFiles() }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .help(file.path)
                            ProgressView(value: file.progress).controlSize(.mini)
                            Text("\(Format.bytes(file.downloaded)) of \(Format.bytes(file.size))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .task(id: "\(torrent.id)-\(store.tick)") { reloadFiles() }
    }

    private func reloadFiles() {
        let latest = store.files(for: torrent.id)
        if latest != files { files = latest }
    }
}

struct MagnetSheet: View {
    @Environment(TorrentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Magnet Link").font(.headline)
            TextField("magnet:?xt=urn:btih:…", text: $link, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Text("Saving to \(store.downloadFolder.path)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    store.addMagnet(link)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!link.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("magnet:"))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), clip.lowercased().hasPrefix("magnet:") {
                link = clip
            }
        }
    }
}

struct SettingsView: View {
    let updaterModel: UpdaterModel
    @Environment(TorrentStore.self) private var store
    @AppStorage(Defaults.downloadLimitKB) private var downloadLimit = 0
    @AppStorage(Defaults.uploadLimitKB) private var uploadLimit = 0
    @AppStorage(Defaults.stopAtRatio) private var stopAtRatio = false
    @AppStorage(Defaults.ratioLimit) private var ratioLimit = 2.0
    @AppStorage(Defaults.stopAfterTime) private var stopAfterTime = false
    @AppStorage(Defaults.seedMinutes) private var seedMinutes = 24 * 60
    @State private var folder = ""
    @State private var defaultHandlerMessage: String?

    var body: some View {
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(folder).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
            TextField("Download limit (KB/s)", value: $downloadLimit, format: .number)
            TextField("Upload limit (KB/s)", value: $uploadLimit, format: .number)
            Text("0 means unlimited.").font(.caption).foregroundStyle(.secondary)
            Section("Seeding") {
                HStack {
                    Toggle("Stop at ratio", isOn: $stopAtRatio)
                    Spacer()
                    TextField("Ratio", value: $ratioLimit, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden().frame(width: 60).disabled(!stopAtRatio)
                }
                HStack {
                    Toggle("Stop after", isOn: $stopAfterTime)
                    Spacer()
                    TextField("Minutes", value: $seedMinutes, format: .number)
                        .labelsHidden().frame(width: 60).disabled(!stopAfterTime)
                    Text("minutes")
                }
                Text("Finished torrents are paused once a limit is reached. Resuming one keeps it seeding until you quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Magnet links") {
                VStack(alignment: .leading) {
                    Button("Open Magnet Links with Joey", action: makeDefaultHandler)
                    if let defaultHandlerMessage {
                        Text(defaultHandlerMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            UpdateSettingsSection(model: updaterModel)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { folder = store.downloadFolder.path }
        .onChange(of: downloadLimit) { store.applyRateLimits() }
        .onChange(of: uploadLimit) { store.applyRateLimits() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.downloadFolder
        if panel.runModal() == .OK, let url = panel.url {
            store.downloadFolder = url
            folder = url.path
        }
    }

    private func makeDefaultHandler() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "magnet") { error in
            Task { @MainActor in
                defaultHandlerMessage = error.map { "Failed: \($0.localizedDescription)" } ?? "Done."
            }
        }
    }
}
