import AppKit
import Carbon.HIToolbox
import Combine
import HimawariKit
import ServiceManagement
import UniformTypeIdentifiers

/// Himawari is only the live wallpaper: the menu-bar icon, the optional Dock icon,
/// and the wallpaper controls in their menus. The desktop clock is a helper app it runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let wallpaper = WallpaperManager()
    private let monitor = PlaybackMonitor()
    private let peek = DesktopPeek()
    private let music = MusicNowPlaying()
    private var musicWatch: AnyCancellable?
    private var positionWatch: AnyCancellable?
    private var pausedSince: Date? // when Music last stopped reporting "playing"
    private var clockHotKey: HotKey? // ⌃⌥⌘C: show / hide the desktop clock
    private var repairTimer: Timer?
    private var filesHotKey: HotKey? // ⌃⌥⌘D: hide / show the desktop's files
    private var recentSongs: [String] = []
    private var pauseGrace: DispatchWorkItem?
    private static let pauseGraceSeconds: TimeInterval = 3
    private let settings = Settings.shared
    private let clock = ClockHelper()
    /// Music's volume, repeat, shuffle and tone, as last read (the side gear shows them).
    private var deck: MusicNowPlaying.Deck?
    private var deckTimer: Timer?
    private var lastGearTouch: CFTimeInterval = 0 // a knob being turned: don't read over it
    private var lastToneSent: CFTimeInterval = 0
    private var finalTone: DispatchWorkItem?

    func applicationWillTerminate(_ notification: Notification) {
        clock.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        clock.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self // rebuilt every time it opens, so checkmarks are always current
        statusItem.menu = menu
        NSApp.mainMenu = Self.appMenu() // only visible while the Dock icon is on
        applyDockVisibility()

        wallpaper.setVolume(settings.volume, muted: settings.muted)
        if let path = settings.videoPath, FileManager.default.fileExists(atPath: path) {
            wallpaper.load(url: URL(fileURLWithPath: path))
            if settings.lockScreenMatch, !LockScreen.isShowing { LockScreen.show(frameOf: URL(fileURLWithPath: path)) }
            if settings.movingLockScreen {
                MovingLockScreen.shared.adopt(video: URL(fileURLWithPath: path)) // a swap made by hand counts
                // Already made: just checks it's in place. Interrupted (quit mid-conversion): starts again.
                _ = MovingLockScreen.shared.apply(video: URL(fileURLWithPath: path))
                startRepairTimer()
            }
        }
        monitor.onChange = { [weak self] play in
            guard let self else { return }
            wallpaper.setDesktopVisible(monitor.desktopVisible)
            wallpaper.setPlaying(play)
            updateStatusIcon(playing: play && wallpaper.hasVideo)
        }
        monitor.start()
        // ⌃⌥⌘C shows or hides the desktop clock from anywhere (it has no menu of its own once hidden).
        clockHotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey | controlKey, id: 7) { [weak self] in
            onMainActor { self?.toggleDesktopClock() }
        }
        if clockHotKey == nil { Log.write("⌃⌥⌘C is taken by another app: show the clock from the menu instead") }
        // ⌃⌥⌘D hides or shows the desktop's files, with or without music.
        filesHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey | controlKey, id: 8) { [weak self] in
            onMainActor { self?.toggleDesktopFiles() }
        }
        if filesHotKey == nil { Log.write("⌃⌥⌘D is taken by another app: hide the files from the menu instead") }

        // Click the empty desktop: just the wallpaper; click it again: files back.
        peek.onChange = { [weak self] clear in self?.wallpaper.setClear(clear) }
        wallpaper.onClearedClick = { [weak self] in self?.wallpaper.setClear(false) }
        peek.onWallpaperClick = { [weak self] in if self?.wallpaper.cleared == true { self?.wallpaper.setClear(false) } }
        peek.enabled = settings.clickToClearDesktop

        // Apple Music: while a song whose album has motion artwork is playing, the
        // wallpaper becomes that looping video; pause / no video → back to yours.
        music.youtubeFallback = settings.musicWallpaper && settings.musicYouTube
        music.tracksPosition = false // the wallpaper doesn't need the song position: fewer checks, less battery
        PowerState.onChange { [weak self] in
            self?.wallpaper.powerChanged()
            self?.applyMusicWallpaper() // also re-evaluates pausing
        }
        // The side gear and the CD are playable (see GearControls).
        var lastVolumeSent = 0.0
        wallpaper.gearControls.song = { [weak self] in
            guard let self, let track = self.music.track else { return nil }
            return (self.songPosition(), track.duration)
        }
        wallpaper.gearControls.volumeNow = { [weak self] done in
            self?.music.fetchVolume { done(Double($0 ?? 50) / 100) }
        }
        wallpaper.gearControls.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .button(.previous): self.music.previous()
            case .button(.playPause): self.music.playPause()
            case .button(.next): self.music.next()
            case .button(.stop): self.music.pause()
            case .button(.eject): self.music.openMusic()
            case .button(.repeatMode):
                self.deck?.repeating.toggle()
                if let deck = self.deck { self.wallpaper.showDeck(deck); self.music.setRepeat(deck.repeating) }
            case .button(.shuffle):
                self.deck?.shuffling.toggle()
                if let deck = self.deck { self.wallpaper.showDeck(deck); self.music.setShuffle(deck.shuffling) }
            case .button: break
            case .seek(let fraction):
                if let track = self.music.track { self.music.seek(to: fraction * track.duration) }
            case .scrub(let seconds):
                self.music.seek(to: max(0, self.songPosition() + seconds))
            case .volume(let v, let done):
                self.lastGearTouch = CACurrentMediaTime()
                // At most ten changes a second while dragging, and the final one.
                let now = CACurrentMediaTime()
                if done || now - lastVolumeSent > 0.1 {
                    lastVolumeSent = now
                    self.music.setVolume(Int((v * 100).rounded()))
                }
                self.deck?.volume = v
            case .tone(let bass, let treble, let done):
                self.setTone(bass: bass, treble: treble, done: done)
            }
        }

        // Repeat and shuffle can change in Music itself: while the gear shows, look every few seconds.
        deckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            onMainActor {
                guard let self, self.wallpaper.gearActive, CACurrentMediaTime() - self.lastGearTouch > 1.5 else { return }
                self.refreshDeck()
            }
        }
        deckTimer?.tolerance = 1

        // The clock asks what's behind it; the wallpaper answers (and keeps it posted).
        WallpaperTone.onReadingRequest { [weak self] region in self?.wallpaper.clockMoved(to: region) }
        musicWatch = Publishers.CombineLatest4(music.$motionVideo, music.$isPlaying, music.$youtubeVideos, music.$artwork)
            .combineLatest(music.$searching, music.$track)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                onMainActor { self?.applyMusicWallpaper() }
            }
        // A YouTube video on the wallpaper follows the song's position.
        positionWatch = music.$position
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                onMainActor {
                    guard let self else { return }
                    self.updateSong()
                    guard self.wallpaper.showingYouTube else { return }
                    self.wallpaper.syncYouTube(to: seconds, songPlaying: self.music.isPlaying)
                }
            }

        if !wallpaper.hasVideo {
            chooseVideo()
        }
    }

    /// Apple Music motion artwork first; else a YouTube loop of the song; else your own video.
    private func applyMusicWallpaper() {
        // Skipping songs, Music reports "not playing" for a moment (several times, as its two
        // status sources catch up). Only a pause that lasts counts, or every skip would drop
        // back to your own wallpaper and rebuild the scene instead of changing discs.
        if music.isPlaying {
            pausedSince = nil
            pauseGrace?.cancel()
            pauseGrace = nil
        } else if pausedSince == nil, wallpaper.showingMusic {
            // Just stopped: give it a moment, then look again.
            pausedSince = Date()
            let recheck = DispatchWorkItem { [weak self] in onMainActor { self?.applyMusicWallpaper() } }
            pauseGrace = recheck
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseGraceSeconds + 0.1, execute: recheck)
        }
        noteDirection()
        let playingOrSkipping = music.isPlaying
            || pausedSince.map { Date().timeIntervalSince($0) < Self.pauseGraceSeconds } == true
        let on = settings.musicWallpaper && playingOrSkipping
        // Between songs, while the next one's animation is being looked up, keep showing the
        // music (the last animation or the CD) rather than dropping back to your own wallpaper.
        if on, music.searching, wallpaper.showingMusic {
            updateSong()
            return
        }
        wallpaper.setOverride(on ? music.motionVideo : nil)
        // A full-screen web player costs real battery: skip YouTube in Battery Saver.
        let youtube = on && music.motionVideo == nil && settings.musicYouTube && !PowerState.saving ? music.youtubeVideos : nil
        wallpaper.setYouTube(youtube)
        updateSong() // before the scene, which tells a new song's cover from a sharper copy by it
        // Nothing to loop at all: the spinning-CD scene with the cover.
        // While the next song's cover or animation is still being looked up, a CD already on
        // screen stays (no flash of your own video between songs); its cover changes when known.
        let wantsScene = on && music.motionVideo == nil && youtube == nil
        let scene: NSImage?
        if wantsScene, !music.searching, let art = music.artwork { scene = art }
        else if wantsScene, wallpaper.showingScene { scene = music.artwork }
        else { scene = nil }
        if !(scene == nil && wantsScene && wallpaper.showingScene) { wallpaper.setScene(scene) }
        updateSong()
        // Only track the song's position while a YouTube video needs to follow it.
        // (the side-bar player's time and progress, too).
        music.tracksPosition = youtube != nil || (on && (music.motionVideo != nil || scene != nil))
        if youtube != nil { wallpaper.syncYouTube(to: music.position, songPlaying: music.isPlaying) }
        monitor.evaluate()
    }

    /// Where the song is now: Music's last reading, carried forward while it plays.
    private func songPosition() -> Double {
        music.measuredPosition + (music.isPlaying ? CACurrentMediaTime() - music.measuredAt : 0)
    }

    private func refreshDeck() {
        music.fetchDeck { [weak self] deck in
            guard let self, let deck, CACurrentMediaTime() - self.lastGearTouch > 1.5 else { return }
            self.deck = deck
            self.wallpaper.showDeck(deck)
        }
    }

    /// The BASS / TREBLE knobs: a few changes a second while turning, and the last one a moment
    /// later (scripts run side by side, so the final setting must go after the rest).
    private func setTone(bass: Double, treble: Double, done: Bool) {
        lastGearTouch = CACurrentMediaTime()
        // The equalizer as it was before Himawari's preset took over, to put back at 0 / 0.
        let defaults = UserDefaults.standard
        if let deck, deck.preset != MusicNowPlaying.tonePreset || !deck.equalizerOn {
            defaults.set(deck.equalizerOn, forKey: "toneRestoreOn")
            defaults.set(deck.preset, forKey: "toneRestorePreset")
        }
        deck?.bass = bass
        deck?.treble = treble
        deck?.preset = MusicNowPlaying.tonePreset
        deck?.equalizerOn = true
        let restore = (on: defaults.bool(forKey: "toneRestoreOn"), preset: defaults.string(forKey: "toneRestorePreset") ?? "")
        let send = { [weak self] in
            self?.lastToneSent = CACurrentMediaTime()
            self?.music.setTone(bass: bass, treble: treble, restore: restore)
        }
        finalTone?.cancel()
        if done {
            let work = DispatchWorkItem(block: send)
            finalTone = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else if CACurrentMediaTime() - lastToneSent > 0.25 {
            send()
        }
    }

    /// Going back to the song before (Previous) or on to a new one? Music doesn't say, so keep
    /// a short history: returning to the one we just left counts as going back.
    private func noteDirection() {
        guard let track = music.track else { return }
        let key = track.name + "|" + track.artist
        guard key != recentSongs.last else { return }
        refreshDeck()
        if recentSongs.count >= 2, recentSongs[recentSongs.count - 2] == key {
            recentSongs.removeLast()
            wallpaper.discDirection = .backward
        } else {
            recentSongs.append(key)
            if recentSongs.count > 50 { recentSongs.removeFirst() }
            wallpaper.discDirection = .forward
        }
    }

    private func updateSong() {
        wallpaper.setSong(music.track.map {
            SongInfo(title: $0.name, artist: $0.artist, album: $0.album, duration: $0.duration,
                     position: music.measuredPosition, playing: music.isPlaying, measuredAt: music.measuredAt)
        })
    }

    // MARK: - Menu-bar icon

    private func updateStatusIcon(playing: Bool) {
        statusItem.button?.image = Self.sunflowerIcon(bright: playing)
        statusItem.button?.toolTip = "Himawari — \(monitor.reason)"
    }

    /// An 18×18 sunflower drawn in code. Template images are tinted by macOS to
    /// match the menu bar (black on light, white on dark); we only choose opacity.
    private static func sunflowerIcon(bright: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.withAlphaComponent(bright ? 1 : 0.4).set()
            // Twelve petals around a seed disc.
            for i in 0..<12 {
                let angle = CGFloat(i) / 12 * 2 * .pi
                let petal = NSBezierPath(ovalIn: NSRect(x: -1.35, y: 3.6, width: 2.7, height: 4.9))
                var t = AffineTransform(translationByX: c.x, byY: c.y)
                t.rotate(byRadians: angle)
                petal.transform(using: t)
                petal.fill()
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.3, y: c.y - 3.3, width: 6.6, height: 6.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Dock icon

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    /// Right-click on the Dock icon: the same controls (minus the slider,
    /// which Dock menus can't show, and Quit, which the Dock adds itself).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        buildMenu(menu, forDock: true)
        return menu
    }

    /// Left-click on the Dock icon: open the menu-bar menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    /// The menu bar at the top of the screen while Himawari is the active Dock app.
    private static func appMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Himawari", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Himawari", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        return main
    }

    // MARK: - Menu contents

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu, forDock: false)
    }

    private func buildMenu(_ menu: NSMenu, forDock: Bool) {
        menu.removeAllItems()

        let videoName = settings.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let status = NSMenuItem(title: videoName.map { "\(monitor.reason) — \($0)" } ?? "No video chosen",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("Choose Video…", #selector(chooseVideo), key: forDock ? "" : "o"))
        menu.addItem(item(settings.userPaused ? "Resume" : "Pause", #selector(togglePause), key: forDock ? "" : "p"))
        menu.addItem(.separator())

        menu.addItem(item("Mute", #selector(toggleMute), checked: settings.muted))
        if !forDock {
            let volumeLabel = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
            volumeLabel.isEnabled = false
            menu.addItem(volumeLabel)
            menu.addItem(volumeSliderItem())
        }
        menu.addItem(.separator())

        let sizingMenu = NSMenu()
        for mode in VideoSizing.allCases {
            let entry = item(mode.rawValue, #selector(setSizing(_:)), checked: settings.videoSizing == mode)
            entry.representedObject = mode.rawValue
            sizingMenu.addItem(entry)
        }
        sizingMenu.addItem(.separator())
        let gaps = NSMenuItem(title: "Fill Gaps With", action: nil, keyEquivalent: "")
        let gapsMenu = NSMenu()
        for fill in BarFill.allCases {
            let entry = item(fill.rawValue, #selector(setBarFill(_:)), checked: settings.barFill == fill)
            entry.representedObject = fill.rawValue
            gapsMenu.addItem(entry)
        }
        gaps.submenu = gapsMenu
        sizingMenu.addItem(gaps)
        let sizingItem = NSMenuItem(title: "Music Video Sizing", action: nil, keyEquivalent: "")
        sizingItem.submenu = sizingMenu
        menu.addItem(sizingItem)
        menu.addItem(item("Use Apple Music Artwork While Playing", #selector(toggleMusicWallpaper), checked: settings.musicWallpaper))
        let yt = item("    …or a YouTube Loop of the Song", #selector(toggleMusicYouTube), checked: settings.musicYouTube)
        yt.isEnabled = settings.musicWallpaper
        menu.addItem(yt)
        let files = item("Hide Desktop Files", #selector(toggleDesktopFiles), key: "d", checked: wallpaper.cleared)
        files.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(files)
        menu.addItem(item("Click Desktop to Hide Files", #selector(toggleClickToClear), checked: settings.clickToClearDesktop))
        menu.addItem(item("Show Wallpaper on Lock Screen (Still)", #selector(toggleLockScreen), checked: settings.lockScreenMatch))
        let moving = MovingLockScreen.shared.status
        menu.addItem(item("Moving Lock Screen" + (moving.isEmpty ? "" : " (\(moving))"), #selector(toggleMovingLockScreen),
                          checked: settings.movingLockScreen))
        let clock = item("Show Desktop Clock", #selector(toggleDesktopClock), key: "c", checked: HimawariKit.Settings.shared.showClock)
        clock.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(clock)
        menu.addItem(item("Pause When Desktop Is Covered", #selector(toggleCovered), checked: settings.pauseWhenCovered))
        menu.addItem(item("Pause on Battery", #selector(toggleBattery), checked: settings.pauseOnBattery))
        menu.addItem(item("Show in Dock", #selector(toggleDock), checked: settings.showInDock))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        let note = NSMenuItem(title: "Clock options: right-click the clock", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)

        if !forDock {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Himawari", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    private func volumeSliderItem() -> NSMenuItem {
        let slider = NSSlider(value: Double(settings.volume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 20, y: 4, width: 180, height: 22)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        container.addSubview(slider)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: - Actions

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video for your wallpaper"
        panel.allowedContentTypes = [.movie] // .mp4, .mov, .m4v (AVFoundation can't play .webm)
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        settings.videoPath = url.path
        wallpaper.load(url: url)
        if settings.lockScreenMatch { LockScreen.show(frameOf: url) }
        if settings.movingLockScreen { _ = MovingLockScreen.shared.apply(video: url) }
        monitor.evaluate()
    }

    @objc private func setBarFill(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let fill = BarFill(rawValue: raw) else { return }
        settings.barFill = fill
        wallpaper.barFill = fill
    }

    @objc private func setSizing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = VideoSizing(rawValue: raw) else { return }
        settings.videoSizing = mode
        wallpaper.sizing = mode
    }

    @objc private func toggleMusicWallpaper() {
        settings.musicWallpaper.toggle()
        music.youtubeFallback = settings.musicWallpaper && settings.musicYouTube
        applyMusicWallpaper()
    }

    @objc private func toggleMusicYouTube() {
        settings.musicYouTube.toggle()
        music.youtubeFallback = settings.musicWallpaper && settings.musicYouTube
        applyMusicWallpaper()
    }

    @objc private func togglePause() {
        settings.userPaused.toggle()
        monitor.evaluate()
    }

    @objc private func toggleMute() {
        settings.muted.toggle()
        wallpaper.setVolume(settings.volume, muted: settings.muted)
    }

    @objc private func volumeChanged(_ slider: NSSlider) {
        settings.volume = slider.floatValue
        if settings.muted, slider.floatValue > 0 {
            settings.muted = false // moving the slider means you want sound
        }
        wallpaper.setVolume(settings.volume, muted: settings.muted)
    }

    // MARK: - The desktop clock (a helper app inside Himawari.app, running while Himawari does)

    @objc private func toggleDesktopClock() {
        HimawariKit.Settings.shared.showClock.toggle()
        HimawariKit.Settings.broadcastChange()
    }

    /// Just the wallpaper, or the files back (the same as clicking the desktop / the wallpaper).
    @objc private func toggleDesktopFiles() {
        wallpaper.setClear(!wallpaper.cleared)
    }

    /// Your video moving on the lock screen, through the Aerial you've picked (see MovingLockScreen).
    /// macOS may re-download an Aerial at any time: check a few times a day that ours is still in place.
    private func startRepairTimer() {
        repairTimer?.invalidate()
        repairTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            onMainActor { MovingLockScreen.shared.repair() }
        }
    }

    @objc private func toggleMovingLockScreen() {
        if settings.movingLockScreen {
            settings.movingLockScreen = false
            repairTimer?.invalidate()
            repairTimer = nil
            MovingLockScreen.shared.restore()
            return
        }
        guard let path = settings.videoPath else { return }
        let alert = NSAlert()
        alert.messageText = "Show your video moving on the lock screen?"
        alert.informativeText = """
        macOS only moves Aerial wallpapers on the lock screen, so Himawari swaps the video of the \
        Aerials you've picked in System Settings ▸ Wallpaper (and your screen saver) for yours. \
        Apple's videos are kept and come back when you turn this off.

        Converting takes a while: about five times the Aerial's length (often 20–30 minutes), \
        once per video, and keeps the processor busy. Plugging in is a good idea.

        macOS decides when the lock screen moves: on battery it may pause.
        """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = MovingLockScreen.shared.apply(video: URL(fileURLWithPath: path)) {
            let info = NSAlert()
            info.messageText = "Pick an Aerial first"
            info.informativeText = problem
            info.addButton(withTitle: "Open Wallpaper Settings")
            info.addButton(withTitle: "OK")
            if info.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        settings.movingLockScreen = true
        if settings.lockScreenMatch { settings.lockScreenMatch = false } // the Aerial is the lock screen now
        startRepairTimer()
    }

    /// The lock screen can't play video, so it shows a still frame of yours (see LockScreen).
    @objc private func toggleLockScreen() {
        settings.lockScreenMatch.toggle()
        if settings.lockScreenMatch, let path = settings.videoPath {
            LockScreen.show(frameOf: URL(fileURLWithPath: path))
        } else {
            LockScreen.restore()
        }
    }

    @objc private func toggleClickToClear() {
        settings.clickToClearDesktop.toggle()
        peek.enabled = settings.clickToClearDesktop
        if !settings.clickToClearDesktop { wallpaper.setClear(false) }
    }

    @objc private func toggleCovered() {
        settings.pauseWhenCovered.toggle()
        monitor.evaluate()
    }

    @objc private func toggleBattery() {
        settings.pauseOnBattery.toggle()
        monitor.evaluate()
    }

    @objc private func toggleDock() {
        settings.showInDock.toggle()
        applyDockVisibility()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Move Himawari.app to /Applications and try again. "
                + "You may also need to allow it in System Settings → General → Login Items."
            NSApp.activate()
            alert.runModal()
        }
    }
}
