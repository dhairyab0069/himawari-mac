import Foundation

/// The live wallpaper's settings, saved in UserDefaults so they survive restarts.
/// (The desktop services keep their own settings; Himawari is only the wallpaper.)
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "volume": 0.5,
            "muted": true,             // wallpapers are silent unless you ask
            "pauseOnBattery": true,
            "pauseWhenCovered": true,
            "userPaused": false,
            "showInDock": false,
            "musicWallpaper": true,
            "musicYouTube": false,     // the spinning-CD scene instead
            "clickToClearDesktop": true,
            "lockScreenMatch": false,   // it replaces your macOS wallpaper picture: opt in
            "movingLockScreen": false,  // it swaps Aerial videos and converts for a long while: opt in
            "videoSizing": VideoSizing.widescreen.rawValue,
        ])
    }

    var videoPath: String? {
        get { defaults.string(forKey: "videoPath") }
        set { defaults.set(newValue, forKey: "videoPath") }
    }

    var volume: Float {
        get { defaults.float(forKey: "volume") }
        set { defaults.set(newValue, forKey: "volume") }
    }

    var muted: Bool {
        get { defaults.bool(forKey: "muted") }
        set { defaults.set(newValue, forKey: "muted") }
    }

    var pauseOnBattery: Bool {
        get { defaults.bool(forKey: "pauseOnBattery") }
        set { defaults.set(newValue, forKey: "pauseOnBattery") }
    }

    var pauseWhenCovered: Bool {
        get { defaults.bool(forKey: "pauseWhenCovered") }
        set { defaults.set(newValue, forKey: "pauseWhenCovered") }
    }

    /// Paused by hand from the menu (as opposed to paused automatically).
    var userPaused: Bool {
        get { defaults.bool(forKey: "userPaused") }
        set { defaults.set(newValue, forKey: "userPaused") }
    }

    /// While Music plays a song whose album has Apple Music motion artwork, use that as the wallpaper.
    var musicWallpaper: Bool {
        get { defaults.bool(forKey: "musicWallpaper") }
        set { defaults.set(newValue, forKey: "musicWallpaper") }
    }

    /// When the album has no motion artwork, loop the middle of the song's YouTube video instead.
    var musicYouTube: Bool {
        get { defaults.bool(forKey: "musicYouTube") }
        set { defaults.set(newValue, forKey: "musicYouTube") }
    }

    /// Show a still frame of the wallpaper video on the lock screen (as the macOS wallpaper picture).
    var lockScreenMatch: Bool {
        get { defaults.bool(forKey: "lockScreenMatch") }
        set { defaults.set(newValue, forKey: "lockScreenMatch") }
    }

    /// Your video, moving, on the lock screen and as the screen saver (see MovingLockScreen).
    var movingLockScreen: Bool {
        get { defaults.bool(forKey: "movingLockScreen") }
        set { defaults.set(newValue, forKey: "movingLockScreen") }
    }

    /// Click an empty spot on the desktop to hide its files (just the wallpaper); click again for them back.
    var clickToClearDesktop: Bool {
        get { defaults.bool(forKey: "clickToClearDesktop") }
        set { defaults.set(newValue, forKey: "clickToClearDesktop") }
    }

    var videoSizing: VideoSizing {
        get { VideoSizing(rawValue: defaults.string(forKey: "videoSizing") ?? "") ?? .widescreen }
        set { defaults.set(newValue.rawValue, forKey: "videoSizing") }
    }

    /// What fills the bars around the video. (Older builds stored only "blurredBars".)
    var barFill: BarFill {
        get {
            if let raw = defaults.string(forKey: "barFill"), let fill = BarFill(rawValue: raw) { return fill }
            return defaults.bool(forKey: "blurredBars") ? .blurred : .ambient
        }
        set { defaults.set(newValue.rawValue, forKey: "barFill") }
    }

    /// Also show an icon in the Dock (right-click it for the same controls as the menu bar).
    var showInDock: Bool {
        get { defaults.bool(forKey: "showInDock") }
        set { defaults.set(newValue, forKey: "showInDock") }
    }
}

/// How the wallpaper video is sized to the screen.
enum BarFill: String, CaseIterable {
    case ambient = "Soft Colors (Apple Music Style)" // slow glow in the video's own edge colors
    case blurred = "Blurred Video"
    case black = "Black Bars"
}

enum VideoSizing: String, CaseIterable {
    case widescreen = "Widescreen (Bars Top & Bottom)" // whole video, never cropped; bars fill the rest
    case fit = "Show Whole Video"        // nothing cropped; bars (black or blurred) around it
    case fitWidth = "Fit Width"          // full width; trim top/bottom if taller, bars if shorter
    case fill = "Fill Screen"            // cover everything, cropping whatever overflows
}
