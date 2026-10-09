import Foundation
import TorrentCore

enum TorrentState: Int {
    case checking, metadata, downloading, finished, seeding, paused, error, queued

    var label: String {
        switch self {
        case .checking: "Checking"
        case .metadata: "Fetching metadata"
        case .downloading: "Downloading"
        case .finished: "Finished"
        case .seeding: "Seeding"
        case .paused: "Paused"
        case .error: "Error"
        case .queued: "Queued"
        }
    }

    var isActiveDownload: Bool { self == .downloading || self == .metadata || self == .checking }
    var isPaused: Bool { self == .paused || self == .error }
}

struct TorrentItem: Identifiable, Equatable {
    let id: String
    var name: String
    var savePath: String
    var error: String
    var state: TorrentState
    var progress: Double
    var totalWanted: Int64
    var totalDone: Int64
    var uploaded: Int64
    var downloaded: Int64
    var downloadRate: Int
    var uploadRate: Int
    var peers: Int
    var seeds: Int
    var hasMetadata: Bool
    var sequential: Bool
    var addedAt: Date
    var seedingTime: TimeInterval

    var eta: TimeInterval? {
        guard state == .downloading, downloadRate > 0, totalWanted > totalDone else { return nil }
        return Double(totalWanted - totalDone) / Double(downloadRate)
    }

    /// Uploaded relative to the size of the content, as most clients report it.
    var ratio: Double { totalWanted > 0 ? Double(uploaded) / Double(totalWanted) : 0 }

    var isSeeding: Bool { state == .seeding || state == .finished }

    var contentURL: URL { URL(fileURLWithPath: savePath).appendingPathComponent(name) }
}

struct TorrentFile: Identifiable, Equatable {
    let id: Int
    var path: String
    var size: Int64
    var downloaded: Int64
    var priority: Int

    var progress: Double { size > 0 ? Double(downloaded) / Double(size) : 1 }
}

enum EngineEvent {
    case finished(id: String, name: String)
    case metadata(id: String, name: String)
    case error(id: String, message: String)
}

struct EngineError: LocalizedError {
    let errorDescription: String?
}

/// Thin Swift wrapper over the C interface in TorrentCore.
final class Engine {
    private var session: OpaquePointer?

    init(stateDirectory: URL) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        session = tc_session_create(stateDirectory.path)
    }

    func shutdown() {
        guard let session else { return }
        tc_session_destroy(session)
        self.session = nil
    }

    func addTorrentFile(_ url: URL, saveTo folder: URL) throws {
        try withErrorBuffer { tc_add_torrent_file(session, url.path, folder.path, $0, $1) }
    }

    func addMagnet(_ uri: String, saveTo folder: URL) throws {
        try withErrorBuffer { tc_add_magnet(session, uri, folder.path, $0, $1) }
    }

    func pause(_ id: String) { tc_pause(session, id) }
    func resume(_ id: String) { tc_resume(session, id) }
    func recheck(_ id: String) { tc_force_recheck(session, id) }
    func setSequential(_ id: String, _ enabled: Bool) { tc_set_sequential(session, id, enabled ? 1 : 0) }
    func remove(_ id: String, deleteFiles: Bool) { tc_remove(session, id, deleteFiles ? 1 : 0) }

    func setFilePriority(_ id: String, file: Int, priority: Int) {
        tc_set_file_priority(session, id, Int32(file), Int32(priority))
    }

    func setRateLimits(download: Int, upload: Int) {
        tc_set_rate_limits(session, Int32(download), Int32(upload))
    }

    func poll() -> (torrents: [TorrentItem], events: [EngineEvent]) {
        guard let session else { return ([], []) }
        let box = PollBox()
        withExtendedLifetime(box) {
            tc_poll(session, Unmanaged.passUnretained(box).toOpaque(), { ctx, raw in
                let box = Unmanaged<PollBox>.fromOpaque(ctx!).takeUnretainedValue()
                let s = raw!.pointee
                box.torrents.append(TorrentItem(
                    id: String(cString: s.id),
                    name: String(cString: s.name),
                    savePath: String(cString: s.save_path),
                    error: String(cString: s.error),
                    state: TorrentState(rawValue: Int(s.state.rawValue)) ?? .downloading,
                    progress: s.progress,
                    totalWanted: s.total_wanted,
                    totalDone: s.total_wanted_done,
                    uploaded: s.total_uploaded,
                    downloaded: s.total_downloaded,
                    downloadRate: Int(s.download_rate),
                    uploadRate: Int(s.upload_rate),
                    peers: Int(s.num_peers),
                    seeds: Int(s.num_seeds),
                    hasMetadata: s.has_metadata != 0,
                    sequential: s.sequential != 0,
                    addedAt: Date(timeIntervalSince1970: TimeInterval(s.added_time)),
                    seedingTime: TimeInterval(s.seeding_seconds)
                ))
            }, { ctx, kind, id, message in
                let box = Unmanaged<PollBox>.fromOpaque(ctx!).takeUnretainedValue()
                let id = String(cString: id!)
                let message = String(cString: message!)
                switch kind {
                case TC_EVENT_FINISHED: box.events.append(.finished(id: id, name: message))
                case TC_EVENT_METADATA: box.events.append(.metadata(id: id, name: message))
                default: box.events.append(.error(id: id, message: message))
                }
            })
        }
        return (box.torrents, box.events)
    }

    func files(for id: String) -> [TorrentFile] {
        guard let session else { return [] }
        let box = FileBox()
        withExtendedLifetime(box) {
            tc_list_files(session, id, Unmanaged.passUnretained(box).toOpaque()) { ctx, raw in
                let box = Unmanaged<FileBox>.fromOpaque(ctx!).takeUnretainedValue()
                let f = raw!.pointee
                box.files.append(TorrentFile(
                    id: Int(f.index),
                    path: String(cString: f.path),
                    size: f.size,
                    downloaded: f.downloaded,
                    priority: Int(f.priority)
                ))
            }
        }
        return box.files
    }

    private func withErrorBuffer(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws {
        var buffer = [CChar](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, Int32($0.count)) }
        if result != 0 {
            throw EngineError(errorDescription: String(cString: buffer))
        }
    }
}

private final class PollBox {
    var torrents: [TorrentItem] = []
    var events: [EngineEvent] = []
}

private final class FileBox {
    var files: [TorrentFile] = []
}
