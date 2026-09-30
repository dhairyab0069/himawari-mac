import AppKit
import HanabiKit

/// Tells the desktop clock what's behind it, so its text stays readable.
///
/// Whatever is on screen (the video where it sits and the bars' fill around it, the CD scene,
/// or a YouTube video's thumbnail) is described as a brightness function over the screen.
/// From it, a reading of exactly the spot the clock asked about is posted, and posted again
/// whenever it changes noticeably.
@MainActor
final class ToneReporter {
    private var clockRegion: CGRect?                     // where the clock is (fractions of the main screen, y down)
    private var screenLuma: ((Double, Double) -> Double)? // brightness of what's on screen at (u, v)
    private var lastReading: ToneReading?

    /// The clock told us where it is: answer right away, and keep answering for that spot.
    func clockMoved(to region: CGRect) {
        clockRegion = region
        publish(force: true)
    }

    /// On screen now: `frame` drawn at `full` (fractions of the screen, y down), seen only
    /// inside `visible`; everywhere else is `fill` bright.
    func show(_ frame: FrameSampler, visible: CGRect, full: CGRect, fill: Double, force: Bool) {
        screenLuma = { u, v in
            guard full.width > 0, full.height > 0, visible.contains(CGPoint(x: u, y: v)) else { return fill }
            return frame.luma((u - full.minX) / full.width, (v - full.minY) / full.height)
        }
        publish(force: force)
    }

    /// Nothing to report until the next `show` (e.g. a new video's first frame).
    func clear() { screenLuma = nil }

    /// YouTube's player can't be looked into, so measure the video's thumbnail where the video sits.
    /// `stillCurrent` is checked when the thumbnail arrives, in case the video changed meanwhile.
    func showYouTube(id: String, on screen: NSScreen, filling: Bool, stillCurrent: @escaping @MainActor () -> Bool) {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") else { return }
        let f = screen.frame
        let top = screen.menuBarStripHeight / f.height
        let full: CGRect
        if filling {
            let videoAspect = 16.0 / 9.0, screenAspect = f.width / f.height
            full = screenAspect > videoAspect
                ? CGRect(x: 0, y: 0.5 - screenAspect / videoAspect / 2, width: 1, height: screenAspect / videoAspect)
                : CGRect(x: 0.5 - videoAspect / screenAspect / 2, y: 0, width: videoAspect / screenAspect, height: 1)
        } else {
            let height = f.width * 9 / 16 / f.height
            full = CGRect(x: 0, y: top + (1 - top - height) / 2, width: 1, height: height)
        }
        let visible = full.intersection(CGRect(x: 0, y: filling ? 0 : top, width: 1, height: 1))
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let frame = FrameSampler(image), let self, stillCurrent() else { return }
            self.show(frame, visible: visible, full: full, fill: 0, force: true)
        }
    }

    private func publish(force: Bool) {
        guard let screenLuma else { return }
        let reading = WallpaperTone.reading(of: screenLuma, region: clockRegion)
        if !force, let last = lastReading, !Self.differ(last, reading) { return }
        lastReading = reading
        WallpaperTone.post(reading)
    }

    /// Only real changes are worth waking the clock for.
    private static func differ(_ a: ToneReading, _ b: ToneReading) -> Bool {
        zip(a.grid, b.grid).contains { abs($0 - $1) > 0.06 }
            || abs((a.focus ?? -1) - (b.focus ?? -1)) > 0.04 || abs((a.spread ?? -1) - (b.spread ?? -1)) > 0.04
    }
}
