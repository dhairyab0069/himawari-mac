import AppKit
import AVFoundation
import HimawariKit

/// Owns the video player and one borderless window per screen, parked just
/// above the system wallpaper and below the desktop icons.
///
/// All screens share ONE player, so the video is decoded once no matter how
/// many monitors are connected; each screen just shows it through its own layer.
@MainActor
final class WallpaperManager {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var troubleObservers: [NSObjectProtocol] = []
    private var starts = 0 // counts start() calls, so a slow earlier one never overrides a newer one
    private var current: URL?   // what's loaded right now
    private var watchdog: Timer?
    // Brightness sampling, so the desktop clock can pick readable text.
    private var output: AVPlayerItemVideoOutput?
    private var outputItem: AVPlayerItem?
    private let tone = ToneReporter()
    /// Click catchers over the side gear and the CD (they're below Finder's icons otherwise).
    let gearControls = GearControls()                   // tells the desktop clock what's behind it
    private var sceneArt: NSImage?                     // the CD scene, for songs with nothing to loop
    private var scenes: [MusicScene] = []
    private var sceneSong: String? // the song whose cover is on the CD
    /// Which way the next change of discs goes (Previous brings the last disc back from the left).
    var discDirection: DiscDirection = .forward
    private var song: SongInfo?
    private let audio = AudioLevels()
    private var levelsStop: DispatchWorkItem?
    private var audioHeard = false // the tap is carrying sound (else the gear animates itself)
    /// The side gear (and the CD scene) move whenever the desktop can be seen, even while the
    /// video itself is paused for the battery: they cost next to nothing.
    private var desktopVisible = true

    func setDesktopVisible(_ visible: Bool) {
        guard visible != desktopVisible else { return }
        desktopVisible = visible
        scenes.forEach { $0.running = visible }
        applySong()
    }
    private var toneTimer: Timer?
    private var windows: [NSWindow] = []
    /// The desktop's files are hidden: the wallpaper sits above Finder's icons and takes clicks.
    private(set) var cleared = false
    var onClearedClick: (() -> Void)?
    private var chosen: URL?   // your wallpaper video
    private var override: URL? // Apple Music motion artwork, while a song plays
    private var youtube: [String]? // …or a YouTube loop of the song, when there's no motion artwork
    private var youtubeViews: [YouTubeLoopView] = []
    private var canvases: [VideoCanvas] = []
    private var sizeWatch: NSKeyValueObservation?
    private var playing = false

    /// How the video is sized to the screen (Himawari menu ▸ Video Sizing).
    var barFill = Settings.shared.barFill { didSet { applyBarFill() } }

    /// Battery Saver swaps the blurred video for the (still) soft colors, and stops their drift.
    private func applyBarFill() {
        let fill: BarFill = PowerState.saving && barFill == .blurred ? .ambient : barFill
        canvases.forEach { $0.barFill = fill; $0.ambientMotion = !PowerState.saving }
    }

    /// Your own wallpaper always fills the screen; Video Sizing (bars, side gear) is for the music wallpaper.
    private var effectiveSizing: VideoSizing { override != nil ? sizing : .fill }

    var sizing: VideoSizing = Settings.shared.videoSizing {
        didSet {
            canvases.forEach { $0.sizing = effectiveSizing }
            if youtube != nil { let ids = youtube; youtube = nil; setYouTube(ids) } // re-lay out the YouTube loop too
        }
    }

    /// Above the picture macOS draws as wallpaper, below Finder's desktop icons.
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init() {
        // AVPlayer keeps the display awake by default — a wallpaper must not.
        player.preventsDisplaySleepDuringVideoPlayback = false

        // Monitor plugged in / unplugged / resolution changed: rebuild the windows.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            onMainActor { self?.rebuildWindows() }
        }
        // Follow the video's shape as items change, so sizing is exact.
        sizeWatch = player.observe(\.currentItem?.presentationSize, options: [.initial, .new]) { [weak self] player, _ in
            let size = player.currentItem?.presentationSize ?? .zero
            DispatchQueue.main.async {
                onMainActor { self?.canvases.forEach { $0.videoSize = size } }
            }
        }
        rebuildWindows()
    }

    var hasVideo: Bool { chosen != nil || override != nil }

    /// Your chosen wallpaper video.
    /// Just above Finder's desktop icons: covers them.
    private static let clearLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// Hide the desktop's files behind the wallpaper (true), or bring them back.
    func setClear(_ clear: Bool) {
        guard clear != cleared else { return }
        cleared = clear
        for window in windows {
            window.level = clear ? Self.clearLevel : Self.level
            window.ignoresMouseEvents = !clear
            window.orderFrontRegardless()
        }
    }

    func load(url: URL) {
        chosen = url
        if override == nil { start(url) }
    }

    /// Battery Saver turned on/off: re-pick the stream size, redraw without/with the blurred fill.
    func powerChanged() {
        applyBarFill()
        scenes.forEach { $0.lively = !PowerState.saving }
        canvases.forEach { $0.sidesLively = !PowerState.saving }
        toneTimer?.invalidate()
        toneTimer = nil
        startToneSampling()
        if let url = override { override = nil; setOverride(url) }
    }

    /// Temporarily show another video (Apple Music motion artwork); nil = back to yours.
    func setOverride(_ url: URL?) {
        guard url != override else { return }
        override = url
        applySong()
        guard let url else {
            // Back to your video: load it first, then its layout (the other way round, the music's
            // square animation flashes stretched to fill the screen for a moment).
            if let chosen { start(chosen) }
            canvases.forEach { $0.sizing = effectiveSizing }
            return
        }
        canvases.forEach { $0.sizing = effectiveSizing }
        // Pick the sharpest stream that fits this screen (streams otherwise start blurry).
        let full = NSScreen.screens.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }.max() ?? 2560
        let pixels = PowerState.saving ? min(full, 1080) : full // Battery Saver: a lighter stream
        Task { [weak self] in
            let sharpest = await MotionArtwork.bestVariant(of: url, maxSide: pixels)
            guard let self, self.override == url else { return }
            self.start(sharpest)
        }
    }

    private func start(_ url: URL) {
        let wasPlaying = player.rate > 0 || playing
        current = url
        // Only the newest start may take over the player: two loopers on one player crash
        // (AVPlayerLooper throws when its items are already queued elsewhere).
        starts += 1
        let start = starts
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        troubleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        troubleObservers = []
        if url.isFileURL {
            // Seamless: AVPlayerLooper queues copies back to back.
            player.actionAtItemEnd = .advance
            if player.isMuted {
                // Muted: play a picture-only version, so the audio track isn't decoded for nothing.
                Task { [weak self] in
                    let silent = await Self.pictureOnly(url)
                    guard let self, self.starts == start else { return }
                    self.player.removeAllItems()
                    self.looper = AVPlayerLooper(player: self.player, templateItem: silent ?? AVPlayerItem(url: url))
                    if self.playing { self.player.play() }
                }
            } else {
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
        } else {
            // Streamed (Apple Music's motion artwork): keep the item at its end (a queue
            // player would otherwise drop it and go black), then jump back to the start.
            player.actionAtItemEnd = .none
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30 // the loops are ~20 s: buffer the whole thing
            item.preferredPeakBitRate = 0            // no bitrate cap: full quality
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            // A network hiccup: reload the stream shortly.
            for name in [Notification.Name.AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemPlaybackStalled] {
                troubleObservers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        onMainActor { if let self, self.current == url { self.start(url) } }
                    }
                })
            }
        }
        if wasPlaying, youtube == nil, sceneArt == nil { player.play() }
        sampleSoon()
        startWatchdog()
        startToneSampling()
    }

    /// Every 3 s, measure the frame on screen and tell the desktop clock how bright it is.
    private func startToneSampling() {
        guard toneTimer == nil else { return }
        toneTimer = Timer.scheduledTimer(withTimeInterval: PowerState.saving ? 10 : 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleTone() }
        }
    }

    private func sampleTone() {
        // The CD scene and YouTube are measured once, when they appear.
        guard youtube == nil, sceneArt == nil, let item = player.currentItem, let canvas = mainCanvas else { return }
        if outputItem !== item { // the looper swaps items; follow the one on screen
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
            if let old = self.output, let oldItem = outputItem { oldItem.remove(old) }
            item.add(output)
            self.output = output
            outputItem = item
            return // first frame arrives next time
        }
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              let frame = FrameSampler(buffer) else { return }
        let palette = AmbientPalette.from(frame)
        canvases.forEach { $0.showPalette(palette) }
        // What's actually on screen: the video where it is, the bars' fill around it.
        let (visible, full) = canvas.layoutFractions
        let fill: Double
        switch canvas.barFill {
        case .black: fill = 0
        case .ambient: fill = palette.luma
        case .blurred:
            let c = frame.average(CGRect(x: 0, y: 0, width: 1, height: 1))
            fill = FrameSampler.luma(c) * 0.55
        }
        tone.show(frame, visible: visible, full: full, fill: fill, force: false)
    }

    private var mainCanvas: VideoCanvas? { canvases.first { $0.window?.screen == NSScreen.main } ?? canvases.first }

    /// The clock told us where it is.
    func clockMoved(to region: CGRect) { tone.clockMoved(to: region) }

    /// A new video: measure it as soon as its first frames are up, not 3 s later.
    private func sampleSoon() {
        Task { [weak self] in
            for delay in [0.5, 1.2, 2.5] {
                try? await Task.sleep(for: .seconds(delay))
                self?.sampleTone()
            }
        }
    }

    private func youTubeTone(_ id: String) {
        guard let screen = NSScreen.main else { return }
        tone.showYouTube(id: id, on: screen, filling: sizing == .fill) { [weak self] in self?.youtube?.first == id }
    }

    // MARK: - The CD scene

    /// Show the spinning-CD scene for this cover (nil = back to the video).
    func setScene(_ art: NSImage?) {
        guard art !== sceneArt else { return }
        if let art, sceneArt != nil, !scenes.isEmpty {
            // Already showing the CD. The same song's cover again (a sharper copy): repaint the
            // disc in place. A new song's: change discs.
            let sameSong = song.map { "\($0.title)|\($0.artist)" } == sceneSong
            sceneArt = art
            scenes.forEach { sameSong ? $0.repaint(with: art) : $0.setArtwork(art, direction: discDirection) }
            sceneSong = song.map { "\($0.title)|\($0.artist)" }
            sceneTone()
            return
        }
        sceneSong = song.map { "\($0.title)|\($0.artist)" }
        sceneArt = art
        // The CD slides off before the scene goes (see MusicScene.leave); a new scene, if any,
        // is added on top meanwhile.
        let leaving = scenes
        scenes = []
        // …and only once what comes next is actually on screen, never your paused video.
        whenVideoShows { leaving.forEach { scene in scene.leave { scene.removeFromSuperview() } } }
        applySong()
        if art != nil {
            windows.forEach(addScene)
            player.pause() // hidden under the scene: don't decode it
            sceneTone()
        } else {
            if playing, youtube == nil { player.play() }
            tone.clear()
            sampleSoon()
        }
    }

    /// Runs `go` once the video that should be showing has its first frames up (at most 4 s).
    private func whenVideoShows(_ go: @escaping () -> Void) {
        Task { [weak self] in
            for _ in 0..<40 {
                guard let self else { return }
                if self.videoShows { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            go()
        }
    }

    /// The right video is loaded: the music's animation if there is one (by then `current` has
    /// moved off your own video), else yours; or a YouTube video, which covers everything.
    private var videoShows: Bool {
        if youtube != nil { return true }
        guard let item = player.currentItem, item.status == .readyToPlay, item.presentationSize.width > 0 else { return false }
        return override == nil || current != chosen
    }

    /// Puts the click catchers over whatever gear and disc are on screen now.
    func refreshControls() {
        gearControls.update(gear: gear, scenes: scenes, active: gearActive)
    }

    /// The side gear is on screen and playable.
    var gearActive: Bool { desktopVisible && youtube == nil && song != nil && !gear.isEmpty }
    private var gear: [NowPlayingSides] { canvases.compactMap(\.gear) + scenes.compactMap(\.gear) }

    /// Music's volume, repeat, shuffle and tone: the knobs and the display follow.
    func showDeck(_ deck: MusicNowPlaying.Deck) {
        for g in gear {
            g.volume = deck.volume
            g.bass = deck.bass
            g.treble = deck.treble
            g.repeating = deck.repeating
            g.shuffling = deck.shuffling
        }
    }

    /// Something from the music is on the wallpaper (its animation, the CD, or YouTube).
    var showingMusic: Bool { override != nil || youtube != nil || sceneArt != nil }

    private func addScene(to window: NSWindow) {
        guard let art = sceneArt, let content = window.contentView, let screen = window.screen else { return }
        let top = screen.menuBarStripHeight
        let bottom = screen.visibleFrame.minY - screen.frame.minY // above the Dock
        let scene = MusicScene(frame: content.bounds, artwork: art, topInset: top, bottomInset: bottom)
        scene.autoresizingMask = [.width, .height]
        scene.running = desktopVisible
        scene.lively = !PowerState.saving
        content.addSubview(scene)
        scenes.append(scene)
        scene.arrive(from: discDirection)
    }

    private func sceneTone() {
        guard let scene = scenes.first(where: { $0.window?.screen == NSScreen.main }) ?? scenes.first,
              let cg = sceneArt?.cgImage(forProposedRect: nil, context: nil, hints: nil), let frame = FrameSampler(cg),
              scene.bounds.width > 0 else { return }
        let b = scene.bounds, d = scene.discRect
        let disc = CGRect(x: d.minX / b.width, y: (b.height - d.maxY) / b.height, width: d.width / b.width, height: d.height / b.height)
        tone.show(frame, visible: disc, full: disc, fill: scene.palette.luma, force: true)
    }

    // MARK: - Now Playing in the side bars

    /// The song, for the side panels next to Apple Music's artwork and the CD (nil = none).
    func setSong(_ info: SongInfo?) {
        guard info != song else { return }
        song = info
        applySong()
    }

    private func applySong() {
        let onMotion = override != nil && youtube == nil && sceneArt == nil
        // Real levels for the VU meters, only while the gear is visible and a song plays.
        let gearShown = song != nil && (onMotion || sceneArt != nil)
        let wasLive = audio.running
        let wanted = gearShown && desktopVisible && song?.playing == true
        if wanted {
            levelsStop?.cancel(); levelsStop = nil
            audio.start()
        } else if audio.running, levelsStop == nil {
            // Keep listening a little while: switching windows shouldn't tear the tap down and rebuild it.
            let stop = DispatchWorkItem { [weak self] in
                onMainActor {
                    guard let self else { return }
                    self.levelsStop = nil
                    self.audio.stop()
                    Log.write("levels: off")
                    self.canvases.forEach { $0.levelsChanged() }
                    self.scenes.forEach { $0.levelsChanged() }
                }
            }
            levelsStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: stop)
        }
        if wanted, !audio.running { Log.write("levels: not listening: \(audio.problem)") }
        if audio.running != wasLive {
            Log.write(audio.running ? "levels: listening to Music (\(audio.problem))" : "levels: off")
            // The gear switches between the live levels and its own animation.
            canvases.forEach { $0.levelsChanged() }
            scenes.forEach { $0.levelsChanged() }
        }
        canvases.forEach { $0.meterSource = audio }
        scenes.forEach { $0.meterSource = audio }
        canvases.forEach { $0.setSong(onMotion ? song : nil, animating: desktopVisible) }
        scenes.forEach { $0.setSong(song, animating: desktopVisible) }
        refreshControls()
    }

    /// The tap going silent (macOS not letting it hear Music, or the output changing) or coming
    /// back: the gear switches between the live levels and its own animation, so it never freezes.
    private func checkHearing() {
        let heard = audio.hearing
        guard heard != audioHeard else { return }
        audioHeard = heard
        if audio.running {
            Log.write(heard ? "levels: hearing Music" : "levels: the tap is silent, so the gear animates by itself "
                      + "(is Himawari allowed in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording?)")
        }
        canvases.forEach { $0.levelsChanged() }
        scenes.forEach { $0.levelsChanged() }
    }

    /// If the wallpaper ever ends up with nothing playable (black), put it back.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let size = self.player.currentItem?.presentationSize ?? .zero
                if size.width > 0 { self.canvases.forEach { $0.videoSize = size } }
                self.refreshControls() // the gear may have moved (new video shape, scene layout)
                self.checkHearing()
                guard let url = self.current, self.youtube == nil else { return }
                let item = self.player.currentItem
                if item == nil || item?.status == .failed || item?.error != nil {
                    self.start(url)
                } else if self.playing, self.player.rate == 0, item?.status == .readyToPlay {
                    self.player.play() // stopped for no reason: nudge it
                }
            }
        }
    }

    /// Show a YouTube loop of the playing song over every screen (nil = back to the video).
    func setYouTube(_ ids: [String]?) {
        let ids = (ids?.isEmpty ?? true) ? nil : ids
        guard ids != youtube else { return }
        youtube = ids
        youtubeViews.forEach { $0.removeFromSuperview() }
        youtubeViews = []
        applySong()
        if let ids {
            for window in windows { addYouTube(to: window) }
            player.pause() // don't decode a video nobody can see
            youTubeTone(ids[0])
        } else {
            if playing, sceneArt == nil { player.play() }
            tone.clear()
            sampleSoon()
        }
    }

    /// Keep the YouTube video in step with the song Music is playing.
    func syncYouTube(to seconds: Double, songPlaying: Bool) {
        youtubeViews.forEach { $0.sync(to: seconds, playing: songPlaying && playing) }
    }

    var showingYouTube: Bool { youtube != nil }
    var showingScene: Bool { sceneArt != nil }

    private func addYouTube(to window: NSWindow) {
        guard let ids = youtube, let content = window.contentView else { return }
        let view = YouTubeLoopView(ids: ids, fill: sizing == .fill)
        let inset = window.screen?.menuBarStripHeight ?? 0
        view.frame = sizing == .fill ? content.bounds
            : NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - inset) // below the notch strip
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        view.setPlaying(playing)
        youtubeViews.append(view)
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        youtubeViews.forEach { $0.setPlaying(playing) }
        scenes.forEach { $0.running = desktopVisible }
        applySong()
        if playing, hasVideo, youtube == nil, sceneArt == nil {
            player.play()
        } else {
            player.pause() // the last frame stays on screen
        }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        let muteChanged = player.isMuted != muted
        player.volume = volume
        player.isMuted = muted
        // Switch between the picture-only and the with-sound version of a local video.
        if muteChanged, let current, current.isFileURL, youtube == nil, sceneArt == nil { start(current) }
    }

    /// A version of the video with no audio track (nothing to decode but the picture).
    private static func pictureOnly(_ url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false else { return nil } // no audio: nothing to strip
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)) != nil else { return nil }
        track.preferredTransform = (try? await video.load(.preferredTransform)) ?? .identity
        return AVPlayerItem(asset: composition)
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        youtubeViews = []
        canvases = []
        scenes = []
        windows = NSScreen.screens.map(makeWindow)
        windows.forEach(addYouTube)
        windows.forEach(addScene)
        applySong()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        // A non-activating panel: clicking it (to bring the files back) never takes focus from your apps.
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.setFrame(screen.frame, display: false)
        window.level = cleared ? Self.clearLevel : Self.level
        // On every Space, never moves, skipped by Cmd-` and Mission Control.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = !cleared // clicks go through to the desktop
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let canvas = VideoCanvas(player: player, scale: screen.backingScaleFactor)
        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        canvas.sizing = effectiveSizing
        canvas.onClick = { [weak self] in self?.onClearedClick?() }
        canvas.barFill = PowerState.saving && barFill == .blurred ? .ambient : barFill
        canvas.ambientMotion = !PowerState.saving
        canvas.sidesLively = !PowerState.saving
        // The strip under the notch / menu bar is effectively off screen: keep the video below it.
        canvas.topInset = screen.menuBarStripHeight
        canvas.videoSize = player.currentItem?.presentationSize ?? .zero
        window.contentView = canvas
        canvases.append(canvas)

        window.orderFrontRegardless()
        return window
    }
}
