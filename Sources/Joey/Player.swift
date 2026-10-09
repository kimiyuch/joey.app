import AppKit
import CMpv
import MediaPlayer
import OpenGL.GL3
import SwiftUI
import UniformTypeIdentifiers

enum Playback {
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "ogv", "3gp",
    ]

    static func isVideo(_ path: String) -> Bool {
        videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isVideo(_ url: URL) -> Bool {
        isVideo(url.path) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// Finished video files of a torrent, largest first.
    static func videos(in torrent: TorrentItem, files: [TorrentFile]) -> [URL] {
        files
            .filter { $0.size > 0 && $0.downloaded >= $0.size && isVideo($0.path) }
            .sorted { $0.size > $1.size }
            .map { URL(fileURLWithPath: torrent.savePath).appendingPathComponent($0.path) }
    }
}

/// Videos opened from Finder, waiting for a view that can open windows.
@MainActor
@Observable
final class PlayerLauncher {
    static let shared = PlayerLauncher()
    var pending: [URL] = []
}

struct OpenVideoButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Video…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie]
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK {
                panel.urls.forEach { openWindow(id: "player", value: $0) }
            }
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
    }
}

/// Where each file was left off, keyed by path.
enum ResumePositions {
    private static let key = "resumePositions"

    static func position(for url: URL) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[url.path]
    }

    static func save(_ position: Double, duration: Double, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        // Nothing worth resuming right at the start, and a file watched to the end starts over next time.
        all[url.path] = position > 15 && duration - position > 60 ? position : nil
        UserDefaults.standard.set(all, forKey: key)
    }
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let title: String
}

/// One mpv instance playing one file.
@MainActor
@Observable
final class MPVPlayer {
    let url: URL
    private(set) var isPaused = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var videoSize: CGSize?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var audioTrack: Int?
    private(set) var subtitleTrack: Int?

    @ObservationIgnored private var mpv: OpaquePointer?
    @ObservationIgnored private(set) var layer: MPVLayer?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let wakeup = WeakBox<MPVPlayer>()
    @ObservationIgnored private var lastSavedPosition: Double = 0

    var title: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        guard let mpv = mpv_create() else { return }
        self.mpv = mpv
        for (name, value) in [
            ("config", "no"), ("terminal", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("osc", "no"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
            ("vo", "libmpv"), ("hwdec", "auto-safe"), ("keep-open", "yes"), ("sub-auto", "fuzzy"),
        ] {
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
            return
        }
        for (name, format) in [
            ("pause", MPV_FORMAT_FLAG), ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64), ("aid", MPV_FORMAT_STRING),
            ("sid", MPV_FORMAT_STRING), ("track-list", MPV_FORMAT_NONE), ("eof-reached", MPV_FORMAT_FLAG),
        ] {
            mpv_observe_property(mpv, 0, name, format)
        }

        wakeup.value = self
        mpv_set_wakeup_callback(mpv, { ctx in
            let box = Unmanaged<WeakBox<MPVPlayer>>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.drainEvents() } }
        }, Unmanaged.passUnretained(wakeup).toOpaque())

        // The file is loaded once the layer has a GL context; without one mpv would play without video.
        let layer = MPVLayer(mpv: mpv)
        layer.onReady = { [weak self] in self?.load() }
        self.layer = layer
    }

    private func load() {
        var options = ""
        if let start = ResumePositions.position(for: url) { options = "start=\(start)" }
        command(["loadfile", url.path, "replace", "-1", options])
        NowPlaying.shared.activate(self)
    }

    func shutdown() {
        guard let mpv else { return }
        savePosition()
        NowPlaying.shared.deactivate(self)
        layer?.teardown()
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    // MARK: Controls

    func togglePause() { setFlag("pause", !isPaused) }
    func play() { setFlag("pause", false) }
    func pause() { setFlag("pause", true) }

    func seek(to seconds: Double, exact: Bool = true) {
        command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func seek(by seconds: Double) { command(["seek", String(seconds), "relative"]) }

    func selectAudio(_ id: Int?) { setString("aid", id.map(String.init) ?? "no") }
    func selectSubtitle(_ id: Int?) { setString("sid", id.map(String.init) ?? "no") }
    func addSubtitleFile(_ url: URL) { command(["sub-add", url.path, "select"]) }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    // MARK: mpv

    private func drainEvents() {
        while let mpv, let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                propertyChanged(event.data.assumingMemoryBound(to: mpv_event_property.self).pointee)
            case MPV_EVENT_PLAYBACK_RESTART:
                NowPlaying.shared.update(self)
            default:
                break
            }
        }
    }

    private func propertyChanged(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let data = property.data
        switch name {
        case "pause":
            isPaused = data?.assumingMemoryBound(to: Int32.self).pointee != 0
            savePosition()
            NowPlaying.shared.update(self)
        case "time-pos":
            position = data?.assumingMemoryBound(to: Double.self).pointee ?? 0
            if abs(position - lastSavedPosition) >= 10 { savePosition() }
        case "duration":
            duration = data?.assumingMemoryBound(to: Double.self).pointee ?? 0
            NowPlaying.shared.update(self)
        case "dwidth", "dheight":
            let width = int64Property("dwidth"), height = int64Property("dheight")
            videoSize = width > 0 && height > 0 ? CGSize(width: Double(width), height: Double(height)) : nil
        case "aid", "sid":
            let raw = data.flatMap { $0.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee }
            let id = raw.flatMap { Int(String(cString: $0)) }
            if name == "aid" { audioTrack = id } else { subtitleTrack = id }
        case "track-list":
            loadTracks()
        case "eof-reached":
            if data?.assumingMemoryBound(to: Int32.self).pointee != 0 { savePosition() }
        default:
            break
        }
    }

    private struct TrackInfo: Decodable {
        let id: Int
        let type: String
        let title: String?
        let lang: String?
        let codec: String?
    }

    private func loadTracks() {
        guard let mpv, let raw = mpv_get_property_string(mpv, "track-list") else { return }
        defer { mpv_free(raw) }
        let tracks = (try? JSONDecoder().decode([TrackInfo].self, from: Data(String(cString: raw).utf8))) ?? []
        func label(_ track: TrackInfo) -> String {
            let language = track.lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            let parts = [language, track.title].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? "Track \(track.id)" : parts.joined(separator: " – ")
        }
        audioTracks = tracks.filter { $0.type == "audio" }.map { MediaTrack(id: $0.id, title: label($0)) }
        subtitleTracks = tracks.filter { $0.type == "sub" }.map { MediaTrack(id: $0.id, title: label($0)) }
    }

    private func savePosition() {
        guard duration > 0 else { return }
        ResumePositions.save(position, duration: duration, for: url)
        lastSavedPosition = position
    }

    private func int64Property(_ name: String) -> Int64 {
        var value: Int64 = 0
        if let mpv { mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) }
        return value
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        cArgs.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                _ = mpv_command_async(mpv, 0, $0)
            }
        }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
}

// MARK: - Rendering

/// Draws mpv's frames through its OpenGL render API. Everything here runs on the main thread.
final class MPVLayer: CAOpenGLLayer {
    private let mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var glContext: CGLContextObj?
    var onReady: (() -> Void)?

    init(mpv: OpaquePointer) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true
    }

    // Core Animation copies layers for presentation.
    override init(layer: Any) {
        mpv = nil
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        return format ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat format: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: format)
        glContext = context
        createRenderContext()
        return context
    }

    private func createRenderContext() {
        guard let mpv, renderContext == nil, let glContext else { return }
        CGLSetCurrentContext(glContext)
        var glParams = mpv_opengl_init_params(get_proc_address: { _, name in
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }, get_proc_address_ctx: nil)
        let created = MPV_RENDER_API_TYPE_OPENGL.withCString { api in
            withUnsafeMutablePointer(to: &glParams) { glParams in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glParams),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&renderContext, mpv, &params)
            }
        }
        guard created >= 0, let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let layer = Unmanaged<MPVLayer>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { layer.display() }
        }, Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.main.async { [weak self] in self?.onReady?() }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
            return
        }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fbo in
            withUnsafeMutablePointer(to: &flip) { flip in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fbo),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(renderContext, &params)
            }
        }
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }

    /// Must run before the mpv handle is destroyed.
    func teardown() {
        guard let renderContext else { return }
        if let glContext {
            CGLLockContext(glContext)
            CGLSetCurrentContext(glContext)
        }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        if let glContext { CGLUnlockContext(glContext) }
    }
}

final class MPVVideoView: NSView {
    private let videoLayer: MPVLayer

    init(layer: MPVLayer) {
        videoLayer = layer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: MPVPlayer
    let videoSize: CGSize?

    func makeNSView(context: Context) -> MPVVideoView {
        MPVVideoView(layer: player.layer!)
    }

    func updateNSView(_ view: MPVVideoView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            player.window = window
            guard let videoSize, window.contentAspectRatio != videoSize else { return }
            window.contentAspectRatio = videoSize
            if !window.styleMask.contains(.fullScreen) {
                // Keep the width, fit the height to the video, and stay on screen.
                var frame = window.frame
                let height = frame.width * videoSize.height / videoSize.width
                frame.origin.y += frame.height - height
                frame.size.height = height
                if let visible = window.screen?.visibleFrame, frame.height > visible.height {
                    frame.size = CGSize(width: visible.height * videoSize.width / videoSize.height, height: visible.height)
                    frame.origin.y = visible.minY
                }
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}

// MARK: - Now Playing and media keys

@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private weak var player: MPVPlayer?
    private var commandsConfigured = false

    func activate(_ player: MPVPlayer) {
        self.player = player
        configureCommands()
        update(player)
    }

    func deactivate(_ player: MPVPlayer) {
        guard self.player === player else { return }
        self.player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func update(_ player: MPVPlayer) {
        // The most recently started or resumed player owns the media keys.
        if !player.isPaused { self.player = player }
        guard self.player === player else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: player.title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        center.playbackState = player.isPaused ? .paused : .playing
    }

    private func configureCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let commands = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPVPlayer, MPRemoteCommandEvent) -> Void) {
            command.addTarget { [weak self] event in
                guard let player = MainActor.assumeIsolated({ self?.player }) else { return .noActionableNowPlayingItem }
                MainActor.assumeIsolated { action(player, event) }
                return .success
            }
        }
        handle(commands.playCommand) { player, _ in player.play() }
        handle(commands.pauseCommand) { player, _ in player.pause() }
        handle(commands.togglePlayPauseCommand) { player, _ in player.togglePause() }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        handle(commands.skipForwardCommand) { player, _ in player.seek(by: 10) }
        handle(commands.skipBackwardCommand) { player, _ in player.seek(by: -10) }
        handle(commands.changePlaybackPositionCommand) { player, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(to: event.positionTime) }
        }
    }
}

// MARK: - Window

struct PlayerWindow: View {
    let url: URL
    @State private var player: MPVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerView(player: player)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 480, minHeight: 270)
        .navigationTitle(url.lastPathComponent)
        .onAppear { if player == nil { player = MPVPlayer(url: url) } }
        .onDisappear { player?.shutdown() }
    }
}

struct PlayerView: View {
    let player: MPVPlayer
    @State private var showControls = true
    @State private var hoveringControls = false
    @State private var activity = 0
    @State private var scrubPosition: Double?
    @State private var showSubtitleImporter = false

    var body: some View {
        VideoSurface(player: player, videoSize: player.videoSize)
            .onTapGesture(count: 2) { player.toggleFullScreen() }
            .onContinuousHover { phase in
                if case .active = phase { activity += 1 }
            }
            .overlay(alignment: .bottom) {
                controls
                    .padding(16)
                    .opacity(showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
                    .onHover { hoveringControls = $0 }
            }
            .task(id: activity) {
                showControls = true
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                if !player.isPaused && !hoveringControls {
                    showControls = false
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
            .onChange(of: player.isPaused) { activity += 1 }
            .fileImporter(isPresented: $showSubtitleImporter, allowedContentTypes: [.data]) { result in
                if case let .success(url) = result { player.addSubtitleFile(url) }
            }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                player.togglePause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .font(.title2)
            .frame(width: 28)

            Text(Format.time(scrubPosition ?? player.position))
                .monospacedDigit().foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.position },
                    set: { scrubPosition = $0; player.seek(to: $0, exact: false) }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let scrubPosition {
                        player.seek(to: scrubPosition)
                        self.scrubPosition = nil
                    }
                }
            )
            .controlSize(.small)
            Text(Format.time(player.duration))
                .monospacedDigit().foregroundStyle(.secondary)

            Menu {
                Picker("Audio", selection: Binding(get: { player.audioTrack }, set: { player.selectAudio($0) })) {
                    ForEach(player.audioTracks) { Text($0.title).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Audio", systemImage: "speaker.wave.2")
            }
            .disabled(player.audioTracks.count < 2)
            .help("Audio Track")

            Menu {
                Picker("Subtitles", selection: Binding(get: { player.subtitleTrack }, set: { player.selectSubtitle($0) })) {
                    Text("Off").tag(Int?.none)
                    ForEach(player.subtitleTracks) { Text($0.title).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Add Subtitle File…") { showSubtitleImporter = true }
            } label: {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .help("Subtitles")

            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { player.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])

            // Keyboard-only shortcuts.
            Group {
                Button("Back 10 Seconds") { player.seek(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Forward 10 Seconds") { player.seek(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .capsule)
    }
}
