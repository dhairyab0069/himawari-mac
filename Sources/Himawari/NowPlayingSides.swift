import AppKit
import HimawariKit
import QuartzCore

/// What the side panels show about the song.
struct SongInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var playing: Bool
    /// When `position` was true (CACurrentMediaTime).
    var measuredAt: Double = CACurrentMediaTime()
}

/// The bars beside a square video, as two pieces of hi-fi gear: on the left the player (a
/// display with the song, time and progress, transport buttons, a wheel to turn), on the right
/// the meters and knobs. What they look like is the style's (`GearTheme`: the era's layout in a
/// skin's colours); this view builds them and keeps them moving. The hardware is drawn once into
/// an image; only the display, the needles, the meters and the wheels move, with Core Animation
/// at a low frame rate, plus the time text when its seconds change.
@MainActor
final class NowPlayingSides: NSView {
    /// Names this view's click catchers. Not ObjectIdentifier: a view rebuilt after a screen change
    /// can reuse a freed one's address, and its catchers would keep pointing at the old view.
    let catcherKey = UUID().uuidString

    /// The look: switching rebuilds the panels; the song, its position and play state stay.
    var style: Skin = Styles.shared.current {
        didSet {
            guard style != oldValue else { return }
            theme = Themes.make(style, meters: meters)
            rebuild()
        }
    }
    /// The level meters (Customise): the era's own, or needles, LEDs or a spectrum everywhere.
    var meters: StyleOptions.Meters = Styles.shared.options.meters {
        didSet {
            guard meters != oldValue else { return }
            theme = Themes.make(style, meters: meters)
            rebuild()
        }
    }
    /// How much the gear moves by itself (Customise): idle wheels only at full; nothing made-up when still.
    var animation: StyleOptions.Animation = Styles.shared.options.animation { didSet { if animation != oldValue { restartMotion() } } }
    private lazy var theme: GearTheme = Themes.make(style, meters: meters)

    private let deck = CALayer(), analyzer = CALayer()           // the faceplates (drawn hardware)
    private var faces: (left: PanelFace, right: PanelFace)?
    // The display
    private var texts: [TextPart.Role: CATextLayer] = [:]
    private let titleClip = CALayer()
    private var ladder: [CALayer] = []
    private var ladderGlow = true
    private var dialPointer: (layer: CALayer, track: CGRect)?
    private var tape: (left: CALayer, right: CALayer, part: TapePart)?
    private var playLED: CALayer?
    private var rotors: [(layer: CALayer, part: RotorPart)] = []
    /// The knobs' live pointers (VOLUME, BASS, TREBLE): they show, and set, Music's settings.
    private var pointers: [GearControl: CAShapeLayer] = [:]
    /// Where each knob itself is (without its grab margin), in this view's coordinates.
    private var knobRects: [GearControl: CGRect] = [:]
    /// Where each control is, in this view's coordinates (y up).
    private(set) var controlRects: [GearControl: CGRect] = [:]
    /// The controls the playing app supports: the ones the click catchers cover.
    var activeControlRects: [GearControl: CGRect] { controlRects.filter { capabilities.contains($0.key.needs) } }
    /// What the playing app lets the gear do; the other controls are dimmed.
    var capabilities: PlayerCapabilities = .all { didSet { if capabilities != oldValue { dimUnsupported() } } }
    private var dimmers: [CALayer] = []
    /// While the jog wheel is being turned: how far from now the song would land.
    private var previewOffset: Double?
    /// What the time display and progress last showed ("" = draw again).
    private var shownTime = ""
    /// "DHH · 7 / 41": the playlist and the song's place in it, shown instead of the album.
    var playlistLabel: String? {
        didSet { if playlistLabel != oldValue, let info { texts[.album]?.string = playlistLabel ?? info.album } }
    }
    /// Music's volume, 0…1: where the VOLUME knob points.
    var volume: Double = 0.5 { didSet { pointKnobs() } }
    /// BASS and TREBLE in dB, −12…12 (Himawari's equalizer preset in Music).
    var bass: Double = 0 { didSet { pointKnobs() } }
    var treble: Double = 0 { didSet { pointKnobs() } }
    /// Music's REPEAT and SHUFFLE settings, lit on the display.
    var repeating = false { didSet { lightIndicators() } }
    var shuffling = false { didSet { lightIndicators() } }
    // The meters
    private var needles: [CALayer] = []
    private var bars: [(mask: CALayer, part: BarPart)] = []
    /// Live levels of the song (the Core Audio tap); without them the gear animates by itself.
    var meterSource: AudioLevels? { didSet { if meterSource !== oldValue { restartMotion() } } }
    private var meterTimer: Timer?
    private var lastMeterState = ""
    private var needleLevel: [CGFloat] = [0, 0]
    private var bandLevel = [CGFloat](repeating: 0.07, count: AudioLevels.bandCount)

    private var info: SongInfo?
    private var anchor: (position: Double, at: CFTimeInterval) = (0, 0)
    private var video = CGRect.zero
    private var ticker: Timer?
    /// Off in Battery Saver: the needles, meter and jog wheel rest; the display still shows the song.
    var lively = true {
        didSet {
            guard lively != oldValue else { return }
            stopLiveMeters() // restarted at the new frame rate
            restartMotion()
        }
    }
    /// Off while the wallpaper is paused (covered, locked…): the gear stops moving; the time
    /// still follows the song, so it's right the moment you see it again.
    var animating = true { didSet { if animating != oldValue { restartMotion() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(deck)
        layer?.addSublayer(analyzer)
        scheduleTick()
    }

    /// The displayed time is the only thing the app itself updates: exactly when the song's
    /// next second begins, so the digits turn over on the beat, not up to a second late.
    private func scheduleTick() {
        ticker?.invalidate()
        let p = currentPosition()
        let delay = info?.playing == true ? 1 - p.truncatingRemainder(dividingBy: 1) + 0.005 : 1
        ticker = Timer.scheduledTimer(withTimeInterval: max(delay, 0.02), repeats: false) { [weak self] _ in
            onMainActor {
                guard let self else { return }
                self.updateTime()
                self.scheduleTick()
            }
        }
        ticker?.tolerance = 0.005
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ info: SongInfo) {
        let old = self.info
        let songChanged = info.title != old?.title || info.artist != old?.artist
        // Count the seconds ourselves, steadily; only jump when Music is really somewhere
        // else (a seek, a new song, play/pause), not for its small, late corrections.
        let now = CACurrentMediaTime()
        let actual = info.playing ? info.position + (now - info.measuredAt) : info.position
        let drift = abs(actual - currentPosition())
        let reanchor = songChanged || info.playing != old?.playing || drift > 0.15
        if reanchor { anchor = (actual, now) }
        self.info = info
        if reanchor { scheduleTick() } // timed from the new state (e.g. just resumed)
        if songChanged { showSongText() }
        lightIndicators()
        lightLamp()
        updateTime()
        if songChanged || info.playing != old?.playing {
            restartProgress()
            restartMotion()
        } else if drift > 2 {
            restartProgress() // a seek: move the progress line, leave everything else be
        }
    }

    private func showSongText() {
        guard let info else { return }
        let caps = faces?.left.uppercaseSong ?? true
        texts[.title]?.string = caps ? info.title.uppercased() : info.title
        texts[.artist]?.string = caps ? info.artist.uppercased() : info.artist
        texts[.album]?.string = playlistLabel ?? info.album
        layoutTitle()
    }

    private func lightLamp() {
        guard let playLED else { return }
        let playing = info?.playing ?? false
        playLED.backgroundColor = (playing ? Paint.green : NSColor(red: 0.12, green: 0.25, blue: 0.14, alpha: 1)).cgColor
        playLED.shadowOpacity = playing ? 0.9 : 0
    }

    /// Puts the gear in the bars beside `video` (this view's coordinates, y up).
    func place(around video: CGRect) {
        guard video != self.video else { return }
        self.video = video
        rebuild()
    }

    private func rebuild() {
        build()
        if info != nil {
            showSongText()
            lightIndicators()
            lightLamp()
        }
        restartProgress()
        restartMotion()
    }

    /// Where the song is now, as the gear counts it (internal for the tests).
    func currentPosition() -> Double {
        guard let info else { return 0 }
        let p = info.playing ? anchor.position + (CACurrentMediaTime() - anchor.at) : anchor.position
        return info.duration > 0 ? min(max(p, 0), info.duration) : max(p, 0)
    }
    /// The song the gear is showing (for the tests).
    var song: SongInfo? { info }

    private var leftGap: CGRect { CGRect(x: bounds.minX, y: bounds.minY, width: video.minX - bounds.minX, height: bounds.height) }
    private var rightGap: CGRect { CGRect(x: video.maxX, y: bounds.minY, width: bounds.maxX - video.maxX, height: bounds.height) }
    /// Too narrow for the gear (a nearly screen-shaped video): show nothing rather than squeeze.
    private var roomy: Bool { leftGap.width >= 180 && rightGap.width >= 180 && video.height >= 500 }

    // MARK: Building

    private func build() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stopLiveMeters()
        for panel in [deck, analyzer] { panel.sublayers?.forEach { $0.removeFromSuperlayer() } }
        texts = [:]; ladder = []; needles = []; bars = []; rotors = []; pointers = [:]; knobRects = [:]
        dialPointer = nil; tape = nil; playLED = nil; faces = nil
        titleClip.sublayers?.forEach { $0.removeFromSuperlayer() }
        shownTime = "" // new parts: draw the time and progress again
        lastMeterState = ""
        controlRects = [:]
        deck.isHidden = !roomy
        analyzer.isHidden = !roomy
        guard roomy else { dimUnsupported(); return }
        let scale = window?.backingScaleFactor ?? 2
        // The faceplates fill the bars, between the notch strip and the bottom, like rack units.
        deck.frame = CGRect(x: leftGap.minX + 8, y: video.minY + 8, width: leftGap.width - 16, height: video.height - 16)
        analyzer.frame = CGRect(x: rightGap.minX + 8, y: video.minY + 8, width: rightGap.width - 16, height: video.height - 16)
        let left = theme.left(size: deck.bounds.size), right = theme.right(size: analyzer.bounds.size)
        faces = (left, right)
        build(left, in: deck, scale: scale)
        build(right, in: analyzer, scale: scale)
        dimUnsupported()
    }

    private func build(_ face: PanelFace, in panel: CALayer, scale: CGFloat) {
        let size = panel.bounds.size
        panel.contents = Paint.image(size: size, scale: scale) { _ in face.draw(size) }
        panel.contentsScale = scale
        let origin = panel.frame.origin
        let display = style.colors.display

        // Text, over the drawn glass.
        for part in face.texts {
            let t = CATextLayer()
            t.font = Paint.displayFont(style, part.size, part.weight, mono: part.mono)
            t.fontSize = part.size
            t.foregroundColor = display.alpha(Double(part.alpha)).cg
            t.truncationMode = .end
            t.alignmentMode = part.align
            t.contentsScale = scale
            t.shadowColor = display.cg // the glow of a lit display
            t.shadowOpacity = face.glow.opacity
            t.shadowRadius = face.glow.radius
            t.shadowOffset = .zero
            if let s = part.string { t.string = s }
            if part.role == .title {
                titleClip.frame = part.frame
                titleClip.masksToBounds = true
                titleClip.addSublayer(t)
                panel.addSublayer(titleClip)
            } else {
                t.frame = part.frame
                panel.addSublayer(t)
            }
            texts[part.role] = t
        }

        // Progress.
        if !face.ladder.isEmpty { ladderGlow = face.ladderGlow }
        for frame in face.ladder {
            let seg = CALayer()
            seg.frame = frame
            seg.backgroundColor = display.cg
            seg.shadowColor = display.cg
            seg.shadowRadius = 3
            seg.shadowOffset = .zero
            panel.addSublayer(seg)
            ladder.append(seg)
        }
        if let track = face.dialPointer {
            let pointer = CALayer()
            if face.dialDot { // a dot riding a thin line
                let d = min(track.height, 10)
                pointer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                pointer.cornerRadius = d / 2
                pointer.backgroundColor = display.cg
                pointer.shadowColor = NSColor.black.cgColor
                pointer.shadowOpacity = 0.3
                pointer.shadowRadius = 2
                pointer.shadowOffset = CGSize(width: 0, height: -1)
            } else { // the red needle across a tuning dial
                pointer.bounds = CGRect(x: 0, y: 0, width: 2.5, height: track.height)
                pointer.backgroundColor = style.colors.peak.cg
                pointer.shadowColor = style.colors.peak.cg
                pointer.shadowOpacity = 0.8
                pointer.shadowRadius = 3
                pointer.shadowOffset = .zero
            }
            pointer.position = CGPoint(x: track.minX, y: track.midY)
            panel.addSublayer(pointer)
            dialPointer = (pointer, track)
        }
        if let part = face.tape {
            let packs = [part.left, part.right].map { center -> CALayer in
                let pack = CALayer()
                pack.position = center
                pack.backgroundColor = part.color
                pack.borderColor = NSColor(white: 0, alpha: 0.35).cgColor
                pack.borderWidth = 0.5
                panel.addSublayer(pack)
                return pack
            }
            tape = (packs[0], packs[1], part)
        }

        // Meters.
        for part in face.bars {
            let column = CALayer()
            column.frame = part.frame
            let n = CGFloat(part.segments)
            for g in 0..<part.segments {
                let seg = CALayer()
                if part.vertical {
                    let h = (part.frame.height - (n - 1) * part.gap) / n
                    seg.frame = CGRect(x: 0, y: CGFloat(g) * (h + part.gap), width: part.frame.width, height: h)
                } else {
                    let w = (part.frame.width - (n - 1) * part.gap) / n
                    seg.frame = CGRect(x: CGFloat(g) * (w + part.gap), y: 0, width: w, height: part.frame.height)
                }
                seg.backgroundColor = part.colors[min(g, part.colors.count - 1)]
                column.addSublayer(seg)
            }
            if let glow = part.glow {
                column.shadowColor = glow
                column.shadowRadius = 3
                column.shadowOpacity = 0.6
                column.shadowOffset = .zero
            }
            // Each column's mask is what moves.
            let mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.anchorPoint = part.centred ? CGPoint(x: 0.5, y: 0.5) : part.vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            mask.bounds = column.bounds
            mask.position = part.centred ? CGPoint(x: column.bounds.midX, y: column.bounds.midY)
                : part.vertical ? CGPoint(x: column.bounds.midX, y: 0) : CGPoint(x: 0, y: column.bounds.midY)
            if part.centred, part.segments == 1 { column.sublayers?.first?.cornerRadius = part.frame.width / 2 }
            column.mask = mask
            panel.addSublayer(column)
            bars.append((mask, part))
        }
        for faceRect in face.needles {
            // The needle turns about a pivot just below the face; the face clips it.
            let clip = CALayer()
            clip.frame = faceRect
            clip.masksToBounds = true
            clip.cornerRadius = 6
            let needle = CAShapeLayer()
            let length = faceRect.height * 1.12
            needle.bounds = CGRect(x: 0, y: 0, width: 3, height: length)
            needle.anchorPoint = CGPoint(x: 0.5, y: 0)
            needle.position = CGPoint(x: faceRect.width / 2, y: -faceRect.height * 0.28)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1.5, y: 0)); path.addLine(to: CGPoint(x: 1.5, y: length))
            needle.path = path
            needle.strokeColor = style.colors.ink.mixed(SkinColor(0, 0, 0), 0.33).alpha(0.9).cg
            needle.lineWidth = 1.6
            needle.transform = CATransform3DMakeRotation(Paint.needleRest, 0, 0, 1)
            clip.addSublayer(needle)
            let glass = CAGradientLayer() // the reflection on the meter's glass, over the needle
            glass.frame = clip.bounds
            glass.colors = [NSColor(white: 1, alpha: 0.28).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            glass.startPoint = CGPoint(x: 0.5, y: 1)
            glass.endPoint = CGPoint(x: 0.5, y: 0.45)
            clip.addSublayer(glass)
            panel.addSublayer(clip)
            needles.append(needle)
        }
        for rect in face.meshes { // the mesh of a real fluorescent display, over its text
            let mesh = CALayer()
            mesh.frame = rect
            mesh.backgroundColor = Paint.meshColor
            mesh.cornerRadius = 6
            panel.addSublayer(mesh)
        }
        if let rect = face.lamp {
            let led = CALayer()
            led.frame = rect
            led.cornerRadius = rect.width / 2
            led.shadowColor = Paint.green.cgColor
            led.shadowRadius = 4
            led.shadowOffset = .zero
            panel.addSublayer(led)
            playLED = led
        }
        for part in face.rotors {
            let rotor = CALayer()
            rotor.frame = part.frame
            rotor.contents = Paint.image(size: part.frame.size, scale: scale) { _ in part.draw(part.frame.width) }
            rotor.contentsScale = scale
            panel.addSublayer(rotor)
            rotors.append((rotor, part))
        }

        // The knobs' pointers are live: they show (and set) Music's volume, bass and treble.
        for (control, rect) in face.knobs {
            let w = rect.width
            let pointer = CAShapeLayer()
            pointer.bounds = CGRect(x: 0, y: 0, width: w, height: w)
            pointer.position = CGPoint(x: rect.midX, y: rect.midY)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: w / 2, y: w / 2 + w * 0.12))
            line.addLine(to: CGPoint(x: w / 2, y: w / 2 + w * 0.36))
            pointer.path = line
            pointer.strokeColor = Paint.pointerColor(style)
            pointer.lineWidth = 2
            pointer.lineCap = .round
            panel.addSublayer(pointer)
            pointers[control] = pointer
            knobRects[control] = rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        for (control, rect) in face.controls { controlRects[control] = rect.offsetBy(dx: origin.x, dy: origin.y) }
        pointKnobs()
    }

    // MARK: Being played with (see GearControls)

    /// Shades the controls this player can't use (Spotify has no equalizer Himawari can shape, say).
    private func dimUnsupported() {
        dimmers.forEach { $0.removeFromSuperlayer() }
        dimmers = []
        guard let root = layer, roomy else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (control, rect) in controlRects where !capabilities.contains(control.needs) {
            let shade = CALayer()
            // Knobs' click areas reach past the knob (easier to grab): shade only the knob
            // itself, so its label underneath stays readable.
            let knob = knobRects[control]
            shade.frame = (knob ?? rect).insetBy(dx: -2, dy: -2)
            shade.cornerRadius = knob != nil || control == .jog ? shade.frame.width / 2 : 5 // knobs and wheels are round
            shade.backgroundColor = NSColor(white: 0.04, alpha: 0.62).cgColor
            root.addSublayer(shade)
            dimmers.append(shade)
        }
        CATransaction.commit()
    }

    /// A button was pressed: flash it, like a lit button on the real thing.
    func press(_ control: GearControl) {
        guard let rect = controlRects[control], let root = layer else { return }
        let flash = CALayer()
        flash.frame = rect
        flash.cornerRadius = 5
        flash.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
        root.addSublayer(flash)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        flash.add(fade, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { flash.removeFromSuperlayer() }
    }

    /// The jog wheel under your finger: turned to `angle`, previewing the song `seconds` from now.
    func scrub(by seconds: Double, angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (rotor, part) in rotors {
            rotor.removeAnimation(forKey: "spin")
            rotor.transform = CATransform3DMakeRotation(angle * part.scrubRatio, 0, 0, 1)
        }
        CATransaction.commit()
        previewOffset = seconds
        updateTime()
    }

    func endScrub() {
        previewOffset = nil
        for (rotor, _) in rotors { rotor.transform = CATransform3DIdentity }
        restartMotion()
        updateTime()
    }

    /// Where a knob points, 0…1 round its scale.
    func knobValue(_ control: GearControl) -> Double {
        switch control {
        case .volume: volume
        case .bass: (bass + 12) / 24
        case .treble: (treble + 12) / 24
        default: 0
        }
    }

    private func pointKnobs() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // From 7 o'clock (0) round to 5 o'clock (full), like the drawn scale; BASS and TREBLE
        // point straight up at 0 dB.
        for (control, pointer) in pointers {
            let v = CGFloat(min(max(knobValue(control), 0), 1))
            pointer.transform = CATransform3DMakeRotation(.pi * 0.75 - .pi * 1.5 * v, 0, 0, 1)
        }
        CATransaction.commit()
    }

    private func lightIndicators() {
        let playing = info?.playing ?? false
        for (i, lit) in [playing, !playing, repeating, shuffling].enumerated() {
            texts[.indicator(i)]?.opacity = lit ? 1 : 0.16
        }
    }

    private func layoutTitle() {
        guard let title = texts[.title] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = titleClip.bounds.height
        let w = max(titleClip.bounds.width, Self.width(of: title))
        title.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        title.position = CGPoint(x: w / 2, y: h / 2)
        CATransaction.commit()
    }

    // MARK: Motion

    /// The progress follows the clock (see `updateTime`).
    private func restartProgress() { updateTime() }

    /// The live levels started or stopped.
    func levelsChanged() { restartMotion() }

    private func restartMotion() {
        guard let info, roomy, faces != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The gear's own made-up motion (live levels aren't made up: they show even when still).
        let moving = info.playing && lively && animating && animation != .still
        // Live levels keep going in Battery Saver too (at half the frame rate): resting needles
        // while the song plays looked broken. Only the gear's own made-up animation rests.
        let live = info.playing && animating && (meterSource?.hearing ?? false)
        let meterState = live ? "live" : moving ? "self-animated" : "resting"
        if meterState != lastMeterState {
            lastMeterState = meterState
            Log.write("meters: \(meterState) (playing \(info.playing), lively \(lively), animating \(animating), hearing \(meterSource?.hearing ?? false))")
        }
        if live { startLiveMeters() } else { stopLiveMeters() }

        // A title too long for the display scrolls, pausing at each end.
        layoutTitle()
        if let title = texts[.title] {
            title.removeAllAnimations()
            let overflow = title.bounds.width - titleClip.bounds.width
            if overflow > 0, lively, animating, animation != .still {
                let scroll = CAKeyframeAnimation(keyPath: "position.x")
                let x0 = title.bounds.width / 2
                scroll.values = [x0, x0, x0 - overflow, x0 - overflow, x0]
                let travel = Double(overflow) / 24
                let totalTime = 3 + travel + 2 + travel * 0.4
                scroll.keyTimes = [0, 3 / totalTime, (3 + travel) / totalTime, (5 + travel) / totalTime, 1].map { NSNumber(value: $0) }
                scroll.duration = totalTime
                scroll.repeatCount = .infinity
                scroll.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                title.add(scroll, forKey: "marquee")
            }
        }

        for (rotor, part) in rotors {
            rotor.removeAllAnimations()
            guard moving, animation == .full, let period = part.spin else { continue }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = -2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = period < 4 ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
                                                      : CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            rotor.add(spin, forKey: "spin")
        }

        for (i, needle) in needles.enumerated() {
            needle.removeAllAnimations()
            if !live { needle.transform = CATransform3DMakeRotation(Paint.needleRest, 0, 0, 1) }
            guard moving, !live else { continue }
            // Swings like a VU meter on music: mostly -7…0 dB, the odd peak into the red.
            let swing = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let values = Self.vuWander().map(Paint.needleAngle)
            swing.values = values + [values[0]]
            swing.duration = 6.5 + Double(i) * 0.7
            swing.calculationMode = .cubic
            swing.repeatCount = .infinity
            swing.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            needle.add(swing, forKey: "swing")
        }

        for (mask, part) in bars {
            mask.removeAllAnimations()
            if !live { mask.transform = Self.barScale(0.07, part) }
            guard moving, !live else { continue }
            let bounce = CAKeyframeAnimation(keyPath: part.vertical ? "transform.scale.y" : "transform.scale.x")
            switch part.source {
            case .band(let i):
                // Low bands move big and slow, high bands small and quick.
                let top = 1 - Double(i) * 0.045
                let levels = (0..<8).map { _ in Double.random(in: 0.12...top) }
                bounce.values = levels + [levels[0]]
                bounce.duration = 2.4 - Double(i) * 0.1 + Double.random(in: 0...0.4)
                bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 20, preferred: 15)
            case .channel(let i):
                let levels = Self.vuWander()
                bounce.values = levels + [levels[0]]
                bounce.duration = 6.5 + Double(i) * 0.7
                bounce.calculationMode = .cubic
                bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            }
            bounce.repeatCount = .infinity
            mask.add(bounce, forKey: "level")
        }
    }

    /// Made-up VU levels for a meter with nothing to listen to: mostly −7…0 dB, the odd peak.
    private static func vuWander() -> [Double] {
        (0..<24).map { _ in Double.random(in: 0...1) < 0.12 ? Double.random(in: 0.82...0.97) : Double.random(in: 0.38...0.8) }
    }

    private static func barScale(_ level: CGFloat, _ part: BarPart) -> CATransform3D {
        part.vertical ? CATransform3DMakeScale(1, level, 1) : CATransform3DMakeScale(level, 1, 1)
    }

    // MARK: Live meters

    private func startLiveMeters() {
        guard meterTimer == nil else { return }
        _ = meterSource?.read() // drop what piled up while nobody was looking
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / meterRate, repeats: true) { [weak self] timer in
            onMainActor {
                guard let self else { timer.invalidate(); return }
                self.stepMeters()
            }
        }
        meterTimer?.tolerance = 0.004
    }

    /// Frames a second for the live meters: 30, or 15 in Battery Saver.
    private var meterRate: Double { lively ? 30 : 15 }
    /// A per-frame smoothing amount tuned at 30 fps, for the current rate (same feel at 15).
    private func perFrame(_ k: CGFloat) -> CGFloat { 1 - pow(1 - k, CGFloat(30 / meterRate)) }

    private func stopLiveMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// One frame of real VU ballistics: needles rise fast and fall slower; spectrum bars jump
    /// up to the level and drop back gradually, like the real thing.
    private func stepMeters() {
        guard let source = meterSource, source.running else { stopLiveMeters(); restartMotion(); return }
        let s = source.read()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, rms) in [s.left, s.right].enumerated() {
            let target = CGFloat(Self.vuFraction(rms))
            needleLevel[i] += (target - needleLevel[i]) * perFrame(target > needleLevel[i] ? 0.4 : 0.16)
            if i < needles.count {
                needles[i].transform = CATransform3DMakeRotation(Paint.needleAngle(Double(needleLevel[i])), 0, 0, 1)
            }
        }
        for (mask, part) in bars {
            switch part.source {
            case .band(let i) where i < s.bands.count:
                let target = max(CGFloat(s.bands[i]), 0.07)
                bandLevel[i] = target > bandLevel[i] ? target : max(target, bandLevel[i] - 0.04 * CGFloat(30 / meterRate))
                mask.transform = Self.barScale(bandLevel[i], part)
            case .channel(let i) where i < 2:
                mask.transform = Self.barScale(min(max(needleLevel[i], 0.02), 1), part)
            default:
                break
            }
        }
        CATransaction.commit()
    }

    /// Holds the meters at a typical level, for still pictures of the gear (previews, the docs).
    func showSampleLevels() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let levels: [CGFloat] = [0.74, 0.66]
        for (i, needle) in needles.enumerated() { needle.transform = CATransform3DMakeRotation(Paint.needleAngle(Double(levels[i % 2])), 0, 0, 1) }
        let bands: [CGFloat] = [0.55, 0.72, 0.8, 0.66, 0.6, 0.7, 0.52, 0.45, 0.38, 0.3]
        for (mask, part) in bars {
            switch part.source {
            case .band(let i): mask.transform = Self.barScale(bands[i % bands.count], part)
            case .channel(let i): mask.transform = Self.barScale(levels[i % 2], part)
            }
        }
        CATransaction.commit()
    }

    nonisolated static var vuMarks: [(dB: Double, fraction: Double)] { Paint.vuMarks }
    nonisolated static var zeroVU: Double { Paint.zeroVU }

    /// RMS (0…1) → place on the VU scale (0 = −20, 0.82 = 0 VU, 1 = +3). 0 VU is set at
    /// −14 dBFS, where modern masters sit, so the needles live around the 0 mark.
    nonisolated static func vuFraction(_ rms: Float) -> Double {
        let vu = 20 * log10(Double(max(rms, 1e-6))) + 14
        let marks = vuMarks
        if vu <= -20 { return 0 }
        for j in 1..<marks.count where vu <= marks[j].0 {
            let (a0, f0) = marks[j - 1], (a1, f1) = marks[j]
            return f0 + (vu - a0) / (a1 - a0) * (f1 - f0)
        }
        return 1.03 // pinned
    }

    private func updateTime() {
        guard let info else { return }
        func mmss(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
        let p = min(max(currentPosition() + (previewOffset ?? 0), 0), max(info.duration, 0))
        let fraction = info.duration > 0 ? p / info.duration : 0
        let remaining = info.duration > 0 ? "-" + mmss(info.duration - p) : ""
        let lit = Int((fraction * Double(ladder.count)).rounded(.up))
        let fine = Int(fraction * 400) // the dial pointer and the tape move in small steps
        // Redraw only when something visible changes (the parts are rebuilt with the gear: see build).
        let key = "\(mmss(p))|\(remaining)|\(lit)|\(fine)"
        guard key != shownTime else { return }
        shownTime = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        texts[.time]?.string = mmss(p)
        texts[.total]?.string = remaining
        for (i, seg) in ladder.enumerated() {
            seg.opacity = i < lit ? 1 : 0.13
            seg.shadowOpacity = i < lit && ladderGlow ? 0.8 : 0
        }
        if let (pointer, track) = dialPointer {
            pointer.position = CGPoint(x: track.minX + track.width * fraction, y: track.midY)
        }
        if let (left, right, part) = tape {
            for (pack, amount) in [(left, 1 - fraction), (right, fraction)] {
                let r = Self.tapeRadius(amount, hub: part.hub, full: part.full)
                pack.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
                pack.cornerRadius = r
            }
        }
        CATransaction.commit()
    }

    /// How big a reel's pack of tape is when it holds `amount` (0…1) of the tape: the tape's
    /// area, not its radius, grows in step with it.
    nonisolated static func tapeRadius(_ amount: Double, hub: CGFloat, full: CGFloat) -> CGFloat {
        let a = CGFloat(min(max(amount, 0), 1))
        return (hub * hub + (full * full - hub * hub) * a).squareRoot()
    }

    // MARK: Helpers

    private static func width(of layer: CATextLayer) -> CGFloat {
        guard let string = layer.string as? String, let font = layer.font as? NSFont else { return 0 }
        return ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width) + 2
    }
}

/// The side gear's controls that respond to clicks.
enum GearControl: Hashable {
    case previous, playPause, next, stop, eject
    case progress   // click the ladder to jump there
    case jog        // turn to scrub
    case volume     // drag up / down
    case bass, treble          // drag up / down; double-click for flat
    case repeatMode, shuffle   // the words on the display: click to switch

    /// What the playing app must support for this control to work.
    var needs: PlayerCapabilities {
        switch self {
        case .previous, .playPause, .next, .stop: .transport
        case .eject: [] // opens the player: always works
        case .progress, .jog: .seek
        case .volume: .volume
        case .bass, .treble: .equalizer
        case .repeatMode, .shuffle: .repeatShuffle
        }
    }

    /// The knob's label, for the knobs.
    var knobName: String? {
        switch self {
        case .volume: "VOLUME"
        case .bass: "BASS"
        case .treble: "TREBLE"
        default: nil
        }
    }

    init?(knob name: String) {
        switch name {
        case "VOLUME": self = .volume
        case "BASS": self = .bass
        case "TREBLE": self = .treble
        default: return nil
        }
    }
}
