import AppKit
import AVFoundation

/// The lock screen and login screen show the macOS wallpaper picture, and apps can't draw
/// there. So, to match them to the live wallpaper, a still frame of your video becomes that
/// picture: taken a quarter of the way in (past fades from black), at the screen's full
/// resolution. The picture you had before is remembered and put back when this is turned off.
@MainActor
enum LockScreen {
    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Himawari/Lock Screen")
    private static let backupKey = "lockScreenOriginalWallpapers" // screen name → the picture before

    /// Uses a frame of `video` as the wallpaper picture on every screen.
    static func show(frameOf video: URL) {
        rememberOriginals()
        let pixels = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880
        Task {
            let asset = AVURLAsset(url: video)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let at = CMTime(seconds: duration.isFinite && duration > 0 ? duration * 0.25 : 0, preferredTimescale: 600)
            guard let (frame, _) = try? await generator.image(at: at) else {
                Log.write("lock screen: couldn't take a frame of \(video.lastPathComponent)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: frame)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A new file name each time: macOS caches wallpaper pictures by path.
            for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: old)
            }
            let file = folder.appending(path: "Himawari-\(Int(Date().timeIntervalSince1970)).png")
            guard (try? png.write(to: file)) != nil else { return }
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
            }
            Log.write("lock screen: showing a frame of \(video.lastPathComponent)")
        }
    }

    /// Is one of our frames the wallpaper picture right now?
    static var isShowing: Bool {
        NSScreen.screens.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0)?.path.hasPrefix(folder.path) == true }
    }

    /// Puts back the wallpaper pictures you had before.
    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: backupKey) as? [String: String] else { return }
        for screen in NSScreen.screens {
            guard let path = saved[screen.localizedName] ?? saved.values.first else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The first time: note each screen's own picture (not one of ours).
    private static func rememberOriginals() {
        guard UserDefaults.standard.dictionary(forKey: backupKey) == nil else { return }
        var saved: [String: String] = [:]
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), !url.path.hasPrefix(folder.path) {
                saved[screen.localizedName] = url.path
            }
        }
        UserDefaults.standard.set(saved, forKey: backupKey)
    }
}
