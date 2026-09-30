import AppKit
import Combine
import HanabiKit
import ServiceManagement
import UniformTypeIdentifiers

/// Hanabi is only the live wallpaper: the menu-bar icon, the optional Dock icon,
/// and the wallpaper controls in their menus. The desktop folders, clock,
/// widgets and XP taskbar are separate background apps ("Desktop Shell").
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let wallpaper = WallpaperManager()
    private let monitor = PlaybackMonitor()
    private let peek = DesktopPeek()
    private let music = MusicNowPlaying()
    private var musicWatch: AnyCancellable?
    private var positionWatch: AnyCancellable?
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self // rebuilt every time it opens, so checkmarks are always current
        statusItem.menu = menu
        NSApp.mainMenu = Self.appMenu() // only visible while the Dock icon is on
        applyDockVisibility()

        wallpaper.setVolume(settings.volume, muted: settings.muted)
        if let path = settings.videoPath, FileManager.default.fileExists(atPath: path) {
            wallpaper.load(url: URL(fileURLWithPath: path))
        }
        monitor.onChange = { [weak self] play in
            guard let self else { return }
            wallpaper.setDesktopVisible(monitor.desktopVisible)
            wallpaper.setPlaying(play)
            updateStatusIcon(playing: play && wallpaper.hasVideo)
        }
        monitor.start()

        // Click the empty desktop: just the wallpaper; click it again: files back.
        peek.onChange = { [weak self] clear in self?.wallpaper.setClear(clear) }
        wallpaper.onClearedClick = { [weak self] in self?.wallpaper.setClear(false) }
        peek.enabled = settings.clickToClearDesktop

        // Apple Music: while a song whose album has motion artwork is playing, the
        // wallpaper becomes that looping video; pause / no video → back to yours.
        music.youtubeFallback = settings.musicWallpaper && settings.musicYouTube
        music.tracksPosition = false // the wallpaper doesn't need the song position: fewer checks, less battery
        PowerState.onChange { [weak self] in
            self?.wallpaper.powerChanged()
            self?.applyMusicWallpaper() // also re-evaluates pausing
        }
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
        let on = settings.musicWallpaper && music.isPlaying
        wallpaper.setOverride(on ? music.motionVideo : nil)
        // A full-screen web player costs real battery: skip YouTube in Battery Saver.
        let youtube = on && music.motionVideo == nil && settings.musicYouTube && !PowerState.saving ? music.youtubeVideos : nil
        wallpaper.setYouTube(youtube)
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

    private func updateSong() {
        wallpaper.setSong(music.track.map {
            SongInfo(title: $0.name, artist: $0.artist, album: $0.album, duration: $0.duration,
                     position: music.measuredPosition, playing: music.isPlaying, measuredAt: music.measuredAt)
        })
    }

    // MARK: - Menu-bar icon

    private func updateStatusIcon(playing: Bool) {
        statusItem.button?.image = Self.fireworkIcon(bright: playing)
        statusItem.button?.toolTip = "Hanabi — \(monitor.reason)"
    }

    /// An 18×18 firework drawn in code. Template images are tinted by macOS to
    /// match the menu bar (black on light, white on dark); we only choose opacity.
    private static func fireworkIcon(bright: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.withAlphaComponent(bright ? 1 : 0.4).set()
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4 + .pi / 8
                let long = i.isMultiple(of: 2)
                let (inner, outer): (CGFloat, CGFloat) = long ? (3.2, 6.6) : (3.2, 5.2)
                let ray = NSBezierPath()
                ray.lineWidth = 1.5
                ray.lineCapStyle = .round
                ray.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
                ray.line(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
                ray.stroke()
                if long { // a spark at the end of the long rays
                    let d = outer + 1.9
                    NSBezierPath(ovalIn: NSRect(x: c.x + cos(angle) * d - 0.9, y: c.y + sin(angle) * d - 0.9,
                                                width: 1.8, height: 1.8)).fill()
                }
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
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

    /// The menu bar at the top of the screen while Hanabi is the active Dock app.
    private static func appMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Hanabi", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Hanabi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        menu.addItem(item("Click Desktop to Hide Files", #selector(toggleClickToClear), checked: settings.clickToClearDesktop))
        menu.addItem(item("Pause When Desktop Is Covered", #selector(toggleCovered), checked: settings.pauseWhenCovered))
        menu.addItem(item("Pause on Battery", #selector(toggleBattery), checked: settings.pauseOnBattery))
        menu.addItem(desktopShellItem())
        menu.addItem(item("Show in Dock", #selector(toggleDock), checked: settings.showInDock))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        let note = NSMenuItem(title: "Desktop folders, clock, widgets & taskbar: Start ▸ Desktop Settings",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)

        if !forDock {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Hanabi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    // MARK: - Desktop Shell (the optional background services, carried inside Hanabi.app)

    private var shellScript: URL? { Bundle.main.url(forResource: "shell", withExtension: "sh") }
    private var shellInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/Desktop Shell/Desktop Clock.app")
    }

    private func desktopShellItem() -> NSMenuItem {
        let entry = NSMenuItem(title: "Desktop Shell", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if shellScript == nil {
            let none = NSMenuItem(title: "Not included in this build", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else if shellInstalled {
            // Bring back a clock hidden from its own right-click menu.
            sub.addItem(item("Show Desktop Clock", #selector(toggleDesktopClock), checked: HanabiKit.Settings.shared.showClock))
            sub.addItem(.separator())
            sub.addItem(item("Update Desktop Shell", #selector(updateShell)))
            sub.addItem(item("Remove Desktop Shell…", #selector(removeShell)))
        } else {
            sub.addItem(item("Install Desktop Shell…", #selector(installShell)))
        }
        entry.submenu = sub
        return entry
    }

    @objc private func toggleDesktopClock() {
        HanabiKit.Settings.shared.showClock.toggle()
        HanabiKit.Settings.broadcastChange()
    }

    @objc private func installShell() {
        let alert = NSAlert()
        alert.messageText = "Install the Desktop Shell?"
        alert.informativeText = """
        Five background services that restyle your desktop (each can be turned off later with \
        Start ▸ Desktop Settings, and all of it removed from this menu):

        • XP taskbar and Start menu in place of the Dock (tap ⌥ Option for Start)
        • iOS-style desktop folders in place of Finder's desktop icons
        • A big see-through desktop clock
        • A widget panel: Now Playing, calendar, battery, CPU, storage
        • ⌘⌃T opens a Ghostty terminal (if you use Ghostty)

        macOS will ask for Accessibility and folder access the first time they need it.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runShell(["install", Bundle.main.resourceURL!.appending(path: "Desktop Shell").path], done: "The Desktop Shell is installed.")
    }

    @objc private func updateShell() {
        runShell(["install", Bundle.main.resourceURL!.appending(path: "Desktop Shell").path], done: "The Desktop Shell is up to date.")
    }

    @objc private func removeShell() {
        let alert = NSAlert()
        alert.messageText = "Remove the Desktop Shell?"
        alert.informativeText = "The taskbar, folders, clock, widgets and hotkeys stop and are deleted. Your Dock and Finder's desktop icons come back. The wallpaper stays."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runShell(["uninstall"], done: "The Desktop Shell was removed.")
    }

    /// Runs the bundled shell.sh off the main thread, then reports how it went.
    private func runShell(_ arguments: [String], done message: String) {
        guard let script = shellScript else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + arguments
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = ok ? message : "That didn't work"
                alert.informativeText = ok ? "" : String(output.suffix(800))
                alert.runModal()
            }
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
            alert.informativeText = "Move Hanabi.app to /Applications and try again. "
                + "You may also need to allow it in System Settings → General → Login Items."
            NSApp.activate()
            alert.runModal()
        }
    }
}
