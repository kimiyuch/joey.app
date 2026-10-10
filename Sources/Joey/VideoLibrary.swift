import AppKit
import SwiftUI

/// A video somewhere below the video folder.
struct LibraryVideo: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    /// Subfolder path relative to the video folder, empty for files at the top level.
    let folder: String
    let size: Int64
    let added: Date
}

enum VideoLibrary {
    /// The folder set in Settings, or the download folder if none is set.
    static func folder(downloadFolder: URL) -> URL {
        if let path = UserDefaults.standard.string(forKey: Defaults.videoFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return downloadFolder
    }

    /// Every video below `root`, subfolders included, flattened into one list.
    static func scan(_ root: URL, skipping unfinished: Set<String>) -> [LibraryVideo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        var videos: [LibraryVideo] = []
        for case let url as URL in enumerator {
            guard Playback.isVideo(url),
                  !unfinished.contains(url.standardizedFileURL.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let components = url.standardizedFileURL.pathComponents
            videos.append(LibraryVideo(
                url: url,
                name: url.lastPathComponent,
                folder: components.dropFirst(rootDepth).dropLast().joined(separator: "/"),
                size: Int64(values.fileSize ?? 0),
                added: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
            ))
        }
        return videos
    }
}

/// The video folder as a flat list, shown from the player's controls and in the main window's Videos tab.
/// Equatable on `current`, so the player's frequent time updates don't redraw it.
struct VideoLibraryList: View, Equatable {
    /// The file playing in the window, marked in the list.
    var current: URL?
    /// Shows the files left off partway through above the list.
    var showsContinueWatching = false
    let onPlay: (URL) -> Void
    @Environment(TorrentStore.self) private var store
    @State private var videos: [LibraryVideo] = []
    @State private var isScanning = true
    @State private var search = ""
    @AppStorage("videoLibrarySort") private var sort = Sort.name

    enum Sort: String, CaseIterable {
        case name = "Name", added = "Recently Added"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.current == rhs.current && lhs.showsContinueWatching == rhs.showsContinueWatching
    }

    private var folder: URL { VideoLibrary.folder(downloadFolder: store.downloadFolder) }

    private var shown: [LibraryVideo] {
        let terms = search.split(separator: " ")
        let matching = videos.filter { video in
            terms.allSatisfy { video.name.localizedStandardContains($0) || video.folder.localizedStandardContains($0) }
        }
        switch sort {
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .added: return matching.sorted { $0.added > $1.added }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(folder.lastPathComponent)", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { search = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .focusEffectDisabled()

                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort By")

                Button("Rescan", systemImage: "arrow.clockwise", action: scan)
                    .buttonStyle(.borderless)
                    .disabled(isScanning)
                    .help("Rescan")
            }
            .labelStyle(.iconOnly)
            .padding(10)

            ScrollView {
                let positions = WatchHistory.shared.positions()
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsContinueWatching && search.isEmpty {
                        ContinueWatching(onPlay: onPlay)
                    }
                    ForEach(shown) { video in
                        let isCurrent = video.url.standardizedFileURL == current?.standardizedFileURL
                        VideoRow(video: video, resume: positions[video.url.path], isCurrent: isCurrent) { onPlay(video.url) }
                    }
                }
                .padding(.leading, 8)
                // Room for the overlay scroller.
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
            .overlay {
                if isScanning && videos.isEmpty {
                    ProgressView()
                } else if videos.isEmpty {
                    ContentUnavailableView(
                        "No Videos", systemImage: "film.stack",
                        description: Text("Choose a video folder in Joey's settings.")
                    )
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .onAppear(perform: scan)
    }

    private func scan() {
        isScanning = true
        let root = folder
        // Files of downloads still in progress already sit there under their final name.
        let unfinished = Set(store.torrents.flatMap { torrent in
            store.files(for: torrent.id)
                .filter { $0.downloaded < $0.size }
                .map { URL(fileURLWithPath: torrent.savePath).appendingPathComponent($0.path).standardizedFileURL.path }
        })
        Task {
            let found = await Task.detached { VideoLibrary.scan(root, skipping: unfinished) }.value
            videos = found
            isScanning = false
        }
    }
}

/// Cards for the files left off partway through, most recent first. Empty when there are none.
private struct ContinueWatching: View {
    let onPlay: (URL) -> Void

    var body: some View {
        let entries = WatchHistory.shared.continueWatching(limit: 4)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue Watching").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(entries) { entry in
                        ContinueWatchingCard(entry: entry) { onPlay(entry.url) }
                    }
                }
                Text("All Videos").font(.headline).padding(.top, 14)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: WatchHistory.Entry
    let onPlay: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isHovered ? "play.circle.fill" : "film")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    Text(entry.url.deletingPathExtension().lastPathComponent)
                        .lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if entry.duration > 0 {
                    ProgressView(value: entry.progress).controlSize(.small)
                    Text("\(Format.time(entry.duration - entry.position)) left")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Stopped at \(Format.time(entry.position))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(.quaternary.opacity(isHovered ? 0.8 : 0.45), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.url.lastPathComponent)
        .contextMenu {
            Button("Play") { onPlay() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Divider()
            Button("Remove from Continue Watching") { WatchHistory.shared.forget(entry.url) }
        }
    }
}

private struct VideoRow: View {
    let video: LibraryVideo
    let resume: Double?
    let isCurrent: Bool
    let onPlay: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.blue))
                    .opacity(isCurrent || isHovered ? 1 : 0)
                Text(video.name)
                    .lineLimit(1).truncationMode(.middle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer(minLength: 8)
                Text(resume.map(Format.time) ?? "")
                    .foregroundStyle(.tint)
                    .frame(width: 56, alignment: .trailing)
                Text(Format.bytes(video.size))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(isHovered ? 0.5 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
        }
    }
}
