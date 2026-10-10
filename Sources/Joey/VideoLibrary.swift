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
    let release: ReleaseName
}

/// A show's episodes under one header, or a single row without one.
private struct VideoGroup: Identifiable {
    let id: String
    /// The show's name; nil for movies and for the flat Recently Added list.
    let title: String?
    let videos: [LibraryVideo]
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
                added: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast,
                release: ReleaseName(url)
            ))
        }
        return videos
    }
}

/// The video folder as a flat list, shown from the player's controls and in the main window's Watch tab.
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
        return videos.filter { video in
            terms.allSatisfy {
                video.name.localizedStandardContains($0) || video.release.title.localizedStandardContains($0)
                    || video.folder.localizedStandardContains($0)
            }
        }
    }

    /// By name, episodes are grouped by show, with shows and movies in one alphabetical list.
    /// Recently Added is a flat list.
    private func groups(_ videos: [LibraryVideo]) -> [VideoGroup] {
        if sort == .added {
            return [VideoGroup(id: "", title: nil, videos: videos.sorted { $0.added > $1.added })]
        }
        let shows = Dictionary(grouping: videos.filter(\.release.isEpisode), by: \.release.showKey)
            .map { key, episodes in
                let sorted = episodes.sorted {
                    ($0.release.season ?? 0, $0.release.episode ?? 0, $0.name) < ($1.release.season ?? 0, $1.release.episode ?? 0, $1.name)
                }
                return VideoGroup(id: "show:" + key, title: sorted[0].release.title, videos: sorted)
            }
        let movies = videos.filter { !$0.release.isEpisode }
            .map { VideoGroup(id: $0.url.path, title: nil, videos: [$0]) }
        let sorted = (shows + movies).sorted {
            ($0.title ?? $0.videos[0].release.title).localizedStandardCompare($1.title ?? $1.videos[0].release.title) == .orderedAscending
        }
        // Movies next to each other share one block, spaced off from the shows around them.
        return sorted.reduce(into: []) { groups, group in
            if group.title == nil, let last = groups.last, last.title == nil {
                groups[groups.count - 1] = VideoGroup(id: last.id, title: nil, videos: last.videos + group.videos)
            } else {
                groups.append(group)
            }
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
                let history = WatchHistory.shared.entries()
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsContinueWatching && search.isEmpty {
                        ContinueWatching(onPlay: onPlay)
                    }
                    ForEach(groups(shown)) { group in
                        if let title = group.title {
                            ShowHeader(title: title, count: group.videos.count)
                        } else if sort == .name {
                            Spacer().frame(height: 14)
                        }
                        ForEach(Array(group.videos.enumerated()), id: \.element.id) { index, video in
                            VideoRow(
                                video: video,
                                inShow: group.title != nil,
                                isStriped: index % 2 == 0,
                                resume: history[video.url.path],
                                isCurrent: video.url.standardizedFileURL == current?.standardizedFileURL
                            ) { onPlay(video.url) }
                        }
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
                Text("Continue Watching").font(.title2.weight(.bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(entries) { entry in
                        ContinueWatchingCard(entry: entry) { onPlay(entry.url) }
                    }
                }
                Text("All Videos").font(.title2.weight(.bold)).padding(.top, 18)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
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
                let release = ReleaseName(entry.url)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isHovered ? "play.circle.fill" : "film")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.title).fontWeight(.medium).lineLimit(1)
                        if let detail = release.detail {
                            Text(detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if entry.duration > 0 {
                    ProgressView(value: entry.progress).controlSize(.small)
                }
                HStack(spacing: 4) {
                    Text(entry.duration > 0
                         ? "\(Format.time(entry.duration - entry.position)) left"
                         : "Stopped at \(Format.time(entry.position))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 4)
                    VideoBadges(url: entry.url, release: release)
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

private struct ShowHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(count == 1 ? "1 episode" : "\(count) episodes")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct VideoRow: View {
    let video: LibraryVideo
    /// Under a show's header, so the show's name is left out.
    let inShow: Bool
    /// Every other row is shaded.
    let isStriped: Bool
    let resume: WatchHistory.Entry?
    let isCurrent: Bool
    let onPlay: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                title
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Spacer(minLength: 8)
                status
                VideoBadges(url: video.url, release: video.release)
                    .frame(width: 92, alignment: .trailing)
                Text(Format.added(video.added))
                    .foregroundStyle(.tertiary)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(isHovered ? 0.8 : isStriped ? 0.35 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(video.name)\n\(Format.bytes(video.size))")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
            if resume != nil {
                Button("Start from Beginning") { WatchHistory.shared.forget(video.url) }
            }
        }
    }

    @ViewBuilder private var title: some View {
        let release = video.release
        if inShow, let code = release.code {
            HStack(spacing: 10) {
                Text(code).foregroundStyle(.secondary).monospacedDigit()
                Text(release.episodeTitle ?? "Episode \(release.episode ?? 0)")
            }
        } else {
            HStack(spacing: 6) {
                // Movies stand on their own, so their titles weigh as much as a show's.
                Text(release.title).fontWeight(release.isEpisode ? .regular : .semibold)
                if let detail = release.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if isCurrent {
            Label("Playing", systemImage: "play.fill")
                .font(.caption)
                .foregroundStyle(.tint)
        } else if let resume {
            HStack(spacing: 5) {
                if resume.duration > 0 {
                    ProgressRing(value: resume.progress)
                    Text("\(Format.time(resume.duration - resume.position)) left")
                } else {
                    Text("Stopped at \(Format.time(resume.position))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Quality and file type, e.g. "1080p" "MKV".
private struct VideoBadges: View {
    let url: URL
    let release: ReleaseName

    var body: some View {
        HStack(spacing: 4) {
            if let quality = release.quality { Badge(text: quality) }
            Badge(text: url.pathExtension.uppercased())
        }
    }
}

/// A small outlined tag like "1080p" or "MKV".
private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 1))
    }
}

private struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: value)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
    }
}
