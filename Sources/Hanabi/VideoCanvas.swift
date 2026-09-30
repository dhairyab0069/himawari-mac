import AppKit
import AVFoundation
import HanabiKit

/// One screen's wallpaper: the video, sized per `sizing`, with the space around it filled
/// per `barFill` (soft colors, a blurred copy of the video, or black), and the side gear in
/// the bars beside a square video. The blurred copy shows the same player, so the video is
/// still decoded once.
@MainActor
final class VideoCanvas: NSView {
    private let backdrop: AVPlayerLayer
    private let video: AVPlayerLayer
    private let band = CALayer() // clips the video to the visible slice (Widescreen trims tall videos)
    var sizing: VideoSizing = .fitWidth { didSet { if sizing != oldValue { arrange() } } }
    private let ambient = AmbientLayer()
    var barFill: BarFill = .ambient { didSet { if barFill != oldValue { arrange() } } }
    var ambientMotion = true { didSet { ambient.animated = ambientMotion } }
    func showPalette(_ palette: AmbientPalette) { ambient.show(palette) }
    private var sides: NowPlayingSides?
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    var sidesLively = true { didSet { sides?.lively = sidesLively } }
    var meterSource: AudioLevels? { didSet { sides?.meterSource = meterSource } }
    /// The live levels started or stopped: the side gear switches between them and its own animation.
    func levelsChanged() { sides?.levelsChanged() }

    /// Apple Music-style Now Playing in the side bars (nil = none).
    func setSong(_ info: SongInfo?, animating: Bool) {
        guard let info else { sides?.removeFromSuperview(); sides = nil; return }
        if sides == nil {
            let view = NowPlayingSides(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.lively = sidesLively
            view.meterSource = meterSource
            addSubview(view)
            sides = view
            arrange()
        }
        sides?.animating = animating
        sides?.show(info)
    }

    /// Where the picture sits, as fractions of the screen with y down: (visible part, whole video).
    var layoutFractions: (CGRect, CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { let all = CGRect(x: 0, y: 0, width: 1, height: 1); return (all, all) }
        let (visible, full) = frames()
        func fraction(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / bounds.width, y: (bounds.height - r.maxY) / bounds.height,
                   width: r.width / bounds.width, height: r.height / bounds.height)
        }
        return (fraction(visible), fraction(full))
    }
    /// Height of the notch / menu-bar strip at the top, which the video stays below.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { arrange() } } }
    private static let backdropShrink: CGFloat = 10
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { arrange() } } }

    init(player: AVPlayer, scale: CGFloat) {
        backdrop = AVPlayerLayer(player: player)
        video = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        for l in [backdrop, video] { l.contentsScale = scale } // full Retina sharpness (a hand-added layer defaults to 1×)
        layer?.addSublayer(backdrop)
        layer?.addSublayer(ambient)
        band.masksToBounds = true
        band.addSublayer(video)
        layer?.addSublayer(band)
        backdrop.videoGravity = .resizeAspectFill
        backdrop.opacity = 0.55
        // Blurring a full-screen video every frame is expensive. Blur a copy at 1/10 size
        // instead and scale it up: it looks the same (it's a blur) for ~1/100 of the work.
        backdrop.contentsScale = 1
        backdrop.transform = CATransform3DMakeScale(Self.backdropShrink, Self.backdropShrink, 1)
        backdrop.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.5])].compactMap { $0 }
        video.videoGravity = .resize // we size it exactly ourselves
    }

    required init?(coder: NSCoder) { fatalError() }

    // This view doesn't use Auto Layout, so don't wait for a layout pass: arrange
    // the layers directly whenever the size, the mode or the video's shape changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    override func layout() {
        super.layout()
        arrange()
    }

    private func arrange() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let k = Self.backdropShrink
        backdrop.bounds = CGRect(x: 0, y: 0, width: (bounds.width + 120) / k, height: (bounds.height + 120) / k) // overscan: no soft edges
        backdrop.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let (visible, full) = frames()
        band.frame = visible
        video.frame = full.offsetBy(dx: -visible.minX, dy: -visible.minY) // relative to the band
        let covered = visible.contains(bounds)
        backdrop.isHidden = barFill != .blurred || covered
        ambient.isHidden = barFill != .ambient || covered
        if !ambient.isHidden { ambient.arrange(in: bounds, around: visible) }
        sides?.place(around: visible)
        Log.write("sizing \(sizing.rawValue): video \(Int(videoSize.width))×\(Int(videoSize.height)) on screen "
                 + "\(Int(bounds.width))×\(Int(bounds.height)) → visible \(NSStringFromRect(band.frame))")
        CATransaction.commit()
    }

    /// (visible slice on screen, where the whole video sits). They differ only when part is trimmed.
    private func frames() -> (CGRect, CGRect) {
        guard videoSize.width > 0, videoSize.height > 0 else { return (bounds, bounds) }
        if sizing == .widescreen {
            // Never crop: the whole video, as large as fits below the notch. Wide videos span
            // the width (bars above and below); square and tall ones, like Apple Music's
            // artwork, span the height (bars at the sides).
            let area = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - topInset)
            let aspect = videoSize.width / videoSize.height
            let size = aspect >= area.width / area.height ? CGSize(width: area.width, height: area.width / aspect)
                                                          : CGSize(width: area.height * aspect, height: area.height)
            let full = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height).integral
            return (full, full)
        }
        let f = videoFrame()
        return (sizing == .fill ? bounds : f.intersection(bounds), f)
    }

    private func videoFrame() -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        // "Fill" covers everything; the other modes fit the video in the visible area
        // below the notch / menu-bar strip, with bars around it.
        let area = sizing == .fill ? bounds : CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                                        height: bounds.height - topInset) // AppKit: y = 0 is the bottom
        let aspect = videoSize.width / videoSize.height
        let screenAspect = area.width / area.height
        var size: CGSize
        switch sizing {
        case .fitWidth, .widescreen: size = CGSize(width: area.width, height: area.width / aspect)
        case .fill: size = aspect > screenAspect ? CGSize(width: area.height * aspect, height: area.height)
                                                 : CGSize(width: area.width, height: area.width / aspect)
        case .fit: size = aspect > screenAspect ? CGSize(width: area.width, height: area.width / aspect)
                                                : CGSize(width: area.height * aspect, height: area.height)
        }
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height).integral
    }
}
