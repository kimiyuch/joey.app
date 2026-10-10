import AppKit
import IOKit.pwr_mgt
import Observation
import UserNotifications

enum Defaults {
    static let downloadFolder = "downloadFolder"
    static let videoFolder = "videoFolder"
    static let downloadLimitKB = "downloadLimitKB"
    static let uploadLimitKB = "uploadLimitKB"
    static let stopAtRatio = "stopAtRatio"
    static let ratioLimit = "ratioLimit"
    static let stopAfterTime = "stopAfterTime"
    static let seedMinutes = "seedMinutes"
    static let mainTab = "mainTab"

    static func register() {
        UserDefaults.standard.register(defaults: [ratioLimit: 2.0, seedMinutes: 24 * 60])
    }
}

@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [TorrentItem] = []
    /// Increments on every refresh so views can reload derived data (e.g. file lists).
    private(set) var tick = 0
    var lastError: String?

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sleepAssertion: IOPMAssertionID?
    /// Torrents the user resumed after they hit a seeding limit; don't stop them again this session.
    @ObservationIgnored private var limitExempt = Set<String>()

    init() {
        Defaults.register()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        engine = Engine(stateDirectory: support.appendingPathComponent("Joey", isDirectory: true))
        applyRateLimits()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var downloadFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Defaults.downloadFolder) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Defaults.downloadFolder) }
    }

    var totalDownloadRate: Int { torrents.reduce(0) { $0 + $1.downloadRate } }
    var totalUploadRate: Int { torrents.reduce(0) { $0 + $1.uploadRate } }

    // MARK: Adding

    func open(_ urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "magnet" {
                addMagnet(url.absoluteString)
            } else if url.isFileURL {
                do {
                    try engine.addTorrentFile(url, saveTo: downloadFolder)
                } catch {
                    lastError = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        refresh()
    }

    func addMagnet(_ uri: String) {
        do {
            try engine.addMagnet(uri.trimmingCharacters(in: .whitespacesAndNewlines), saveTo: downloadFolder)
        } catch {
            lastError = "Couldn't add magnet link: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: Actions

    func pause(_ ids: Set<String>) { ids.forEach(engine.pause); refresh() }
    func resume(_ ids: Set<String>) {
        limitExempt.formUnion(torrents.filter { ids.contains($0.id) && seedingLimitReached($0) }.map(\.id))
        ids.forEach(engine.resume)
        refresh()
    }

    func pauseAll() { pause(Set(torrents.filter { !$0.state.isPaused }.map(\.id))) }
    func resumeAll() { resume(Set(torrents.filter { $0.state.isPaused }.map(\.id))) }

    func setSequential(_ ids: Set<String>, _ enabled: Bool) {
        ids.forEach { engine.setSequential($0, enabled) }
        refresh()
    }
    func recheck(_ ids: Set<String>) { ids.forEach(engine.recheck); refresh() }

    func remove(_ ids: Set<String>, deleteFiles: Bool) {
        ids.forEach { engine.remove($0, deleteFiles: deleteFiles) }
        refresh()
    }

    func reveal(_ ids: Set<String>) {
        let urls = torrents.filter { ids.contains($0.id) }.map(\.contentURL)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func files(for id: String) -> [TorrentFile] { engine.files(for: id) }

    func setFile(_ file: Int, of id: String, wanted: Bool) {
        engine.setFilePriority(id, file: file, priority: wanted ? 4 : 0)
        refresh()
    }

    func applyRateLimits() {
        let defaults = UserDefaults.standard
        engine.setRateLimits(
            download: defaults.integer(forKey: Defaults.downloadLimitKB) * 1024,
            upload: defaults.integer(forKey: Defaults.uploadLimitKB) * 1024
        )
    }

    func shutdown() {
        timer?.invalidate()
        updateSleepAssertion(active: false)
        engine.shutdown()
    }

    // MARK: Polling

    private func refresh() {
        let (items, events) = engine.poll()
        let sorted = items.sorted { $0.addedAt == $1.addedAt ? $0.name < $1.name : $0.addedAt < $1.addedAt }
        if sorted != torrents { torrents = sorted }
        tick &+= 1

        for event in events {
            switch event {
            case let .finished(_, name): notify(title: "Download finished", body: name)
            case let .error(_, message): notify(title: "Torrent error", body: message)
            case .metadata: break
            }
        }

        for torrent in torrents where torrent.isSeeding && !limitExempt.contains(torrent.id) && seedingLimitReached(torrent) {
            engine.pause(torrent.id)
        }

        let downloading = torrents.filter { $0.state.isActiveDownload }.count
        NSApp?.dockTile.badgeLabel = downloading > 0 ? "\(downloading)" : nil
        updateSleepAssertion(active: downloading > 0)
    }

    private func seedingLimitReached(_ torrent: TorrentItem) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Defaults.stopAtRatio), torrent.ratio >= defaults.double(forKey: Defaults.ratioLimit) {
            return true
        }
        if defaults.bool(forKey: Defaults.stopAfterTime),
           torrent.seedingTime >= TimeInterval(defaults.integer(forKey: Defaults.seedMinutes) * 60) {
            return true
        }
        return false
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Keeps the Mac from idle-sleeping while something is downloading.
    private func updateSleepAssertion(active: Bool) {
        if active, sleepAssertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Downloading torrents" as CFString,
                &id
            )
            if result == kIOReturnSuccess { sleepAssertion = id }
        } else if !active, let id = sleepAssertion {
            IOPMAssertionRelease(id)
            sleepAssertion = nil
        }
    }
}
