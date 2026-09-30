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

/// The bars beside a square video, as two pieces of retro hi-fi gear in a rack:
/// on the left a CD deck (display with the song, time and progress, disc tray,
/// transport buttons, jog wheel), on the right a stereo analyzer (two analog VU
/// meters, a spectrum display, knobs). The hardware is drawn once into an image;
/// only the display, the needles, the meter and the jog wheel move, with Core
/// Animation at a low frame rate, plus the time text when its seconds change.
@MainActor
final class NowPlayingSides: NSView {
    fileprivate static let vfd = NSColor(red: 0.45, green: 0.97, blue: 1, alpha: 1) // vacuum-fluorescent cyan
    fileprivate static let amber = NSColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)

    private let deck = CALayer(), analyzer = CALayer()           // the faceplates (drawn hardware)
    // Deck display
    private let indicators = ["PLAY", "PAUSE", "REPEAT", "SHUFFLE"].map { _ in NowPlayingSides.text(9, .bold, mono: true) }
    private let time = NowPlayingSides.text(40, .light, mono: true)
    private let total = NowPlayingSides.text(12, .medium, alpha: 0.6, mono: true)
    private var ladder: [CALayer] = []
    private let titleClip = CALayer()
    private let title = NowPlayingSides.text(16, .bold)
    private let artist = NowPlayingSides.text(12, .semibold, alpha: 0.8)
    private let album = NowPlayingSides.text(11, .regular, alpha: 0.5)
    private let playLED = CALayer()
    private let jog = CALayer()
    /// The knobs' live pointers (VOLUME, BASS, TREBLE): they show, and set, Music's settings.
    private var pointers: [GearControl: CAShapeLayer] = [:]
    /// Where each control is, in this view's coordinates (y up), for the click catchers.
    private(set) var controlRects: [GearControl: CGRect] = [:]
    /// While the jog wheel is being turned: how far from now the song would land.
    private var previewOffset: Double?
    /// Music's volume, 0…1: where the VOLUME knob points.
    var volume: Double = 0.5 { didSet { pointKnobs() } }
    /// BASS and TREBLE in dB, −12…12 (Himawari's equalizer preset in Music).
    var bass: Double = 0 { didSet { pointKnobs() } }
    var treble: Double = 0 { didSet { pointKnobs() } }
    /// Music's REPEAT and SHUFFLE settings, lit on the display.
    var repeating = false { didSet { lightIndicators() } }
    var shuffling = false { didSet { lightIndicators() } }
    // Analyzer
    private var needles: [CALayer] = []
    /// Live levels of the song (the Core Audio tap); without them the gear animates by itself.
    var meterSource: AudioLevels? { didSet { if meterSource !== oldValue { restartMotion() } } }
    private var meterTimer: Timer?
    private var needleLevel: [CGFloat] = [0, 0]
    private var bandLevel = [CGFloat](repeating: 0.07, count: AudioLevels.bandCount)
    private var columns: [CALayer] = []

    private var info: SongInfo?
    private var anchor: (position: Double, at: CFTimeInterval) = (0, 0)
    private var video = CGRect.zero
    private var ticker: Timer?
    /// Off in Battery Saver: the needles, meter and jog wheel rest; the display still shows the song.
    var lively = true { didSet { if lively != oldValue { restartMotion() } } }
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
        if songChanged {
            title.string = info.title.uppercased()
            artist.string = info.artist.uppercased()
            album.string = info.album
            layoutTitle()
        }
        lightIndicators()
        playLED.backgroundColor = (info.playing ? NSColor(red: 0.3, green: 1, blue: 0.45, alpha: 1)
                                                : NSColor(red: 0.12, green: 0.25, blue: 0.14, alpha: 1)).cgColor
        playLED.shadowOpacity = info.playing ? 0.9 : 0
        updateTime()
        if songChanged || info.playing != old?.playing {
            restartProgress()
            restartMotion()
        } else if drift > 2 {
            restartProgress() // a seek: move the progress line, leave everything else be
        }
    }

    /// Puts the gear in the bars beside `video` (this view's coordinates, y up).
    func place(around video: CGRect) {
        guard video != self.video else { return }
        self.video = video
        build()
        restartProgress()
        restartMotion()
    }

    private func currentPosition() -> Double {
        guard let info else { return 0 }
        let p = info.playing ? anchor.position + (CACurrentMediaTime() - anchor.at) : anchor.position
        return info.duration > 0 ? min(max(p, 0), info.duration) : max(p, 0)
    }

    private var leftGap: CGRect { CGRect(x: bounds.minX, y: bounds.minY, width: video.minX - bounds.minX, height: bounds.height) }
    private var rightGap: CGRect { CGRect(x: video.maxX, y: bounds.minY, width: bounds.maxX - video.maxX, height: bounds.height) }
    /// Too narrow for the gear (a nearly screen-shaped video): show nothing rather than squeeze.
    private var roomy: Bool { leftGap.width >= 180 && rightGap.width >= 180 && video.height >= 500 }

    // MARK: Building

    private func build() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        deck.sublayers?.forEach { $0.removeFromSuperlayer() }
        analyzer.sublayers?.forEach { $0.removeFromSuperlayer() }
        ladder = []; needles = []; columns = []
        controlRects = [:]
        deck.isHidden = !roomy
        analyzer.isHidden = !roomy
        guard roomy else { return }
        let scale = window?.backingScaleFactor ?? 2
        // The faceplates fill the bars, between the notch strip and the bottom, like rack units.
        deck.frame = CGRect(x: leftGap.minX + 8, y: video.minY + 8, width: leftGap.width - 16, height: video.height - 16)
        analyzer.frame = CGRect(x: rightGap.minX + 8, y: video.minY + 8, width: rightGap.width - 16, height: video.height - 16)
        buildDeck(scale: scale)
        buildAnalyzer(scale: scale)
    }

    private func buildDeck(scale: CGFloat) {
        let size = deck.bounds.size
        let l = DeckLayout(size: size)
        deck.contents = Hardware.deck(size: size, layout: l, scale: scale)
        deck.contentsScale = scale

        // The display's contents, over the drawn glass.
        let v = l.display
        let inner = v.insetBy(dx: 14, dy: 12)
        var x = inner.minX
        for (i, name) in ["PLAY", "PAUSE", "REPEAT", "SHUFFLE"].enumerated() {
            let t = indicators[i]
            t.string = name
            let w = Self.width(of: t) + 2
            t.frame = CGRect(x: x, y: inner.maxY - 11, width: w, height: 11)
            x += w + 10
            deck.addSublayer(t)
        }
        // REPEAT and SHUFFLE are buttons too: click the word to switch it.
        for (control, i) in [(GearControl.repeatMode, 2), (.shuffle, 3)] {
            controlRects[control] = indicators[i].frame.insetBy(dx: -4, dy: -5)
                .offsetBy(dx: deck.frame.origin.x, dy: deck.frame.origin.y)
        }
        lightIndicators()
        time.frame = CGRect(x: inner.minX - 2, y: inner.maxY - 64, width: inner.width * 0.62, height: 48)
        total.frame = CGRect(x: inner.minX + inner.width * 0.6, y: inner.maxY - 58, width: inner.width * 0.4, height: 15)
        total.alignmentMode = .right
        deck.addSublayer(time)
        deck.addSublayer(total)
        let segments = 32, gap: CGFloat = 2
        let segW = (inner.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        for s in 0..<segments {
            let seg = CALayer()
            seg.frame = CGRect(x: inner.minX + CGFloat(s) * (segW + gap), y: inner.maxY - 78, width: segW, height: 6)
            seg.backgroundColor = Self.vfd.cgColor
            seg.shadowColor = Self.vfd.cgColor
            seg.shadowRadius = 3
            seg.shadowOffset = .zero
            deck.addSublayer(seg)
            ladder.append(seg)
        }
        titleClip.frame = CGRect(x: inner.minX, y: inner.maxY - 104, width: inner.width, height: 20)
        titleClip.masksToBounds = true
        titleClip.addSublayer(title)
        deck.addSublayer(titleClip)
        artist.frame = CGRect(x: inner.minX, y: inner.maxY - 122, width: inner.width, height: 16)
        album.frame = CGRect(x: inner.minX, y: inner.maxY - 138, width: inner.width, height: 15)
        deck.addSublayer(artist)
        deck.addSublayer(album)
        // The mesh of a real fluorescent display, over its text.
        let mesh = CALayer()
        mesh.frame = v.insetBy(dx: 4, dy: 4)
        mesh.backgroundColor = Hardware.meshColor
        mesh.cornerRadius = 6
        deck.addSublayer(mesh)
        layoutTitle()

        playLED.frame = l.playLED
        playLED.cornerRadius = l.playLED.width / 2
        playLED.shadowColor = NSColor(red: 0.3, green: 1, blue: 0.45, alpha: 1).cgColor
        playLED.shadowRadius = 4
        playLED.shadowOffset = .zero
        deck.addSublayer(playLED)

        let origin = deck.frame.origin
        for (control, rect) in zip([GearControl.previous, .playPause, .next, .stop, .eject], l.buttonRects) {
            controlRects[control] = rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        controlRects[.progress] = CGRect(x: inner.minX, y: inner.maxY - 88, width: inner.width, height: 26)
            .offsetBy(dx: origin.x, dy: origin.y)
        controlRects[.jog] = l.jog.offsetBy(dx: origin.x, dy: origin.y)
        jog.frame = l.jog
        jog.contents = Hardware.jogWheel(diameter: l.jog.width, scale: scale)
        jog.contentsScale = scale
        deck.addSublayer(jog)
        for l in [indicators, [time, total, title, artist, album]].flatMap({ $0 }) { l.contentsScale = scale }
    }

    private func buildAnalyzer(scale: CGFloat) {
        let size = analyzer.bounds.size
        let l = AnalyzerLayout(size: size)
        analyzer.contents = Hardware.analyzer(size: size, layout: l, scale: scale)
        analyzer.contentsScale = scale

        for face in l.meters {
            // The needle turns about a pivot just below the face; the face clips it.
            let clip = CALayer()
            clip.frame = face
            clip.masksToBounds = true
            clip.cornerRadius = 6
            let needle = CAShapeLayer()
            let length = face.height * 1.12
            needle.bounds = CGRect(x: 0, y: 0, width: 3, height: length)
            needle.anchorPoint = CGPoint(x: 0.5, y: 0)
            needle.position = CGPoint(x: face.width / 2, y: -face.height * 0.28)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1.5, y: 0)); path.addLine(to: CGPoint(x: 1.5, y: length))
            needle.path = path
            needle.strokeColor = NSColor(red: 0.12, green: 0.08, blue: 0.06, alpha: 0.9).cgColor
            needle.lineWidth = 1.6
            needle.transform = CATransform3DMakeRotation(Hardware.needleRest, 0, 0, 1)
            clip.addSublayer(needle)
            let glass = CAGradientLayer() // the reflection on the meter's glass, over the needle
            glass.frame = clip.bounds
            glass.colors = [NSColor(white: 1, alpha: 0.28).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            glass.startPoint = CGPoint(x: 0.5, y: 1)
            glass.endPoint = CGPoint(x: 0.5, y: 0.45)
            clip.addSublayer(glass)
            analyzer.addSublayer(clip)
            needles.append(needle)
        }

        // Spectrum: VFD segment columns; each column's mask is what moves.
        let s = l.spectrum
        let count = 10, segments = 14
        let colGap: CGFloat = 5, segGap: CGFloat = 2
        let colW = (s.width - CGFloat(count - 1) * colGap) / CGFloat(count)
        let segH = (s.height - CGFloat(segments - 1) * segGap) / CGFloat(segments)
        for i in 0..<count {
            let column = CALayer()
            column.frame = CGRect(x: s.minX + CGFloat(i) * (colW + colGap), y: s.minY, width: colW, height: s.height)
            for g in 0..<segments {
                let seg = CALayer()
                seg.frame = CGRect(x: 0, y: CGFloat(g) * (segH + segGap), width: colW, height: segH)
                seg.backgroundColor = (g >= segments - 3 ? Self.amber : Self.vfd).cgColor
                column.addSublayer(seg)
            }
            column.shadowColor = Self.vfd.cgColor
            column.shadowRadius = 3
            column.shadowOpacity = 0.6
            column.shadowOffset = .zero
            let mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.anchorPoint = CGPoint(x: 0.5, y: 0)
            mask.bounds = column.bounds
            mask.position = CGPoint(x: column.bounds.midX, y: 0)
            column.mask = mask
            analyzer.addSublayer(column)
            columns.append(mask)
        }
        let mesh = CALayer()
        mesh.frame = l.spectrumGlass.insetBy(dx: 4, dy: 4)
        mesh.backgroundColor = Hardware.meshColor
        mesh.cornerRadius = 6
        analyzer.addSublayer(mesh)

        // The knobs' pointers are live: they show (and set) Music's volume, bass and treble.
        pointers = [:]
        for (rect, name) in l.knobs {
            guard let control = GearControl(knob: name) else { continue }
            let w = rect.width
            let pointer = CAShapeLayer()
            pointer.bounds = CGRect(x: 0, y: 0, width: w, height: w)
            pointer.position = CGPoint(x: rect.midX, y: rect.midY)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: w / 2, y: w / 2 + w * 0.12))
            line.addLine(to: CGPoint(x: w / 2, y: w / 2 + w * 0.36))
            pointer.path = line
            pointer.strokeColor = NSColor(white: 0.95, alpha: 0.9).cgColor
            pointer.lineWidth = 2
            pointer.lineCap = .round
            analyzer.addSublayer(pointer)
            pointers[control] = pointer
            controlRects[control] = rect.insetBy(dx: -10, dy: -10)
                .offsetBy(dx: analyzer.frame.origin.x, dy: analyzer.frame.origin.y)
        }
        pointKnobs()
    }

    // MARK: Being played with (see GearControls)

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
        jog.removeAnimation(forKey: "spin")
        jog.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
        previewOffset = seconds
        updateTime()
    }

    func endScrub() {
        previewOffset = nil
        jog.transform = CATransform3DIdentity
        restartMotion()
        updateTime()
    }

    /// Where the song is shown to be right now (including a jog-wheel preview).
    var shownPosition: Double { currentPosition() }

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
            indicators[i].opacity = lit ? 1 : 0.16
        }
    }

    private func layoutTitle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = max(titleClip.bounds.width, Self.width(of: title))
        title.bounds = CGRect(x: 0, y: 0, width: w, height: 20)
        title.position = CGPoint(x: w / 2, y: 10)
        CATransaction.commit()
    }

    // MARK: Motion

    /// The progress ladder follows the clock (see `updateTime`).
    private func restartProgress() { updateTime() }

    /// The live levels started or stopped.
    func levelsChanged() { restartMotion() }

    private func restartMotion() {
        guard let info, roomy, !needles.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let moving = info.playing && lively && animating
        let live = moving && (meterSource?.running ?? false)
        if live { startLiveMeters() } else { stopLiveMeters() }

        // A title too long for the display scrolls, pausing at each end.
        layoutTitle()
        title.removeAllAnimations()
        let overflow = title.bounds.width - titleClip.bounds.width
        if overflow > 0, lively, animating {
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

        jog.removeAllAnimations()
        if moving {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = -2 * Double.pi
            spin.duration = 9
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            jog.add(spin, forKey: "spin")
        }

        for (i, needle) in needles.enumerated() {
            needle.removeAllAnimations()
            if !live { needle.transform = CATransform3DMakeRotation(Hardware.needleRest, 0, 0, 1) }
            guard moving, !live else { continue }
            // Swings like a VU meter on music: mostly -7…0 dB, the odd peak into the red.
            let swing = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let values = (0..<24).map { _ -> CGFloat in
                let level = Double.random(in: 0...1) < 0.12 ? Double.random(in: 0.82...0.97) : Double.random(in: 0.38...0.8)
                return Hardware.needleAngle(level)
            }
            swing.values = values + [values[0]]
            swing.duration = 6.5 + Double(i) * 0.7
            swing.calculationMode = .cubic
            swing.repeatCount = .infinity
            swing.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            needle.add(swing, forKey: "swing")
        }

        for (i, mask) in columns.enumerated() {
            mask.removeAllAnimations()
            if !live { mask.transform = CATransform3DMakeScale(1, 0.07, 1) }
            guard moving, !live else { continue }
            // Low bands move big and slow, high bands small and quick.
            let top = 1 - Double(i) * 0.045
            let levels = (0..<8).map { _ in Double.random(in: 0.12...top) }
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
            bounce.values = levels + [levels[0]]
            bounce.duration = 2.4 - Double(i) * 0.1 + Double.random(in: 0...0.4)
            bounce.repeatCount = .infinity
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 20, preferred: 15)
            mask.add(bounce, forKey: "level")
        }
    }

    // MARK: Live meters

    private func startLiveMeters() {
        guard meterTimer == nil else { return }
        _ = meterSource?.read() // drop what piled up while nobody was looking
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            onMainActor {
                guard let self else { timer.invalidate(); return }
                self.stepMeters()
            }
        }
        meterTimer?.tolerance = 0.004
    }

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
        for (i, rms) in [s.left, s.right].enumerated() where i < needles.count {
            let target = CGFloat(Self.vuFraction(rms))
            needleLevel[i] += (target - needleLevel[i]) * (target > needleLevel[i] ? 0.4 : 0.16)
            needles[i].transform = CATransform3DMakeRotation(Hardware.needleAngle(Double(needleLevel[i])), 0, 0, 1)
        }
        for (i, mask) in columns.enumerated() where i < s.bands.count {
            let target = max(CGFloat(s.bands[i]), 0.07)
            bandLevel[i] = target > bandLevel[i] ? target : max(target, bandLevel[i] - 0.04)
            mask.transform = CATransform3DMakeScale(1, bandLevel[i], 1)
        }
        CATransaction.commit()
    }

    /// RMS (0…1) → place on the VU scale (0 = −20, 0.82 = 0 VU, 1 = +3). 0 VU is set at
    /// −14 dBFS, where modern masters sit, so the needles live around the 0 mark.
    private static func vuFraction(_ rms: Float) -> Double {
        let vu = 20 * log10(Double(max(rms, 1e-6))) + 14
        let marks: [(Double, Double)] = [(-20, 0), (-10, 0.28), (-7, 0.42), (-5, 0.53), (-3, 0.64), (-2, 0.7),
                                          (-1, 0.76), (0, 0.82), (1, 0.88), (2, 0.94), (3, 1)]
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
        let shown = (time.string as? String, total.string as? String)
        guard shown.0 != mmss(p) || shown.1 == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        time.string = mmss(p)
        total.string = info.duration > 0 ? "-" + mmss(info.duration - p) : ""
        let lit = info.duration > 0 ? Int((p / info.duration * Double(ladder.count)).rounded(.up)) : 0
        for (i, seg) in ladder.enumerated() {
            seg.opacity = i < lit ? 1 : 0.13
            seg.shadowOpacity = i < lit ? 0.8 : 0
        }
        CATransaction.commit()
    }

    // MARK: Helpers

    fileprivate static func text(_ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat = 1, mono: Bool = false) -> CATextLayer {
        let l = CATextLayer()
        l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        l.fontSize = size
        l.foregroundColor = vfd.withAlphaComponent(alpha).cgColor
        l.truncationMode = .end
        l.contentsScale = 2
        l.shadowColor = vfd.cgColor // the glow of a fluorescent display
        l.shadowOpacity = 0.7
        l.shadowRadius = 3.5
        l.shadowOffset = .zero
        return l
    }

    private static func width(of layer: CATextLayer) -> CGFloat {
        guard let string = layer.string as? String, let font = layer.font as? NSFont else { return 0 }
        return ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width) + 2
    }
}

// MARK: - Layouts (faceplate coordinates, y up)

private struct DeckLayout {
    let header, display, tray, buttons, jog, playLED: CGRect
    let buttonRects: [CGRect]
    let column: CGRect

    init(size: CGSize) {
        let colW = min(size.width - 32, 300)
        column = CGRect(x: (size.width - colW) / 2, y: 18, width: colW, height: size.height - 36)
        header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        display = CGRect(x: column.minX, y: header.minY - 14 - 164, width: colW, height: 164)
        tray = CGRect(x: column.minX, y: display.minY - 26 - 16, width: colW, height: 16)
        let row = CGRect(x: column.minX, y: tray.minY - 24 - 34, width: colW, height: 34)
        buttons = row
        let n = 5, gap: CGFloat = 8, left = column.minX
        let bw = (colW - CGFloat(n - 1) * gap) / CGFloat(n)
        let rects = (0..<n).map { CGRect(x: left + CGFloat($0) * (bw + gap), y: row.minY, width: bw, height: 34) }
        buttonRects = rects
        playLED = CGRect(x: rects[1].midX - 3, y: rects[1].maxY + 5, width: 6, height: 6)
        let space = row.minY - 70 - column.minY // leave room for the power row
        let d = max(min(colW - 40, space - 30, 190), 60)
        jog = CGRect(x: column.midX - d / 2, y: column.minY + 60 + (space - d) / 2, width: d, height: d)
    }
}

private struct AnalyzerLayout {
    let header: CGRect
    let meters: [CGRect]
    let spectrum, spectrumGlass, labels: CGRect
    let knobs: [(CGRect, String)]
    let column: CGRect

    init(size: CGSize) {
        let colW = min(size.width - 32, 300)
        column = CGRect(x: (size.width - colW) / 2, y: 18, width: colW, height: size.height - 36)
        header = CGRect(x: column.minX, y: column.maxY - 40, width: colW, height: 40)
        let meterH = min(colW * 0.52, 150)
        let m1 = CGRect(x: column.minX, y: header.minY - 14 - meterH, width: colW, height: meterH)
        let m2 = CGRect(x: column.minX, y: m1.minY - 12 - meterH, width: colW, height: meterH)
        meters = [m1, m2]
        let knobRow: CGFloat = 78
        let available = m2.minY - 24 - (column.minY + knobRow + 20)
        let glassH = max(min(available, 200), 90)
        spectrumGlass = CGRect(x: column.minX, y: m2.minY - 24 - glassH, width: colW, height: glassH)
        labels = CGRect(x: spectrumGlass.minX + 12, y: spectrumGlass.minY + 8, width: colW - 24, height: 10)
        spectrum = CGRect(x: spectrumGlass.minX + 12, y: labels.maxY + 6, width: colW - 24, height: glassH - 34)
        let small: CGFloat = 40, big: CGFloat = 56
        let y = column.minY + 22
        knobs = [(CGRect(x: column.minX + colW * 0.18 - small / 2, y: y + (big - small) / 2, width: small, height: small), "BASS"),
                 (CGRect(x: column.minX + colW * 0.45 - small / 2, y: y + (big - small) / 2, width: small, height: small), "TREBLE"),
                 (CGRect(x: column.minX + colW * 0.78 - big / 2, y: y, width: big, height: big), "VOLUME")]
    }
}

// MARK: - The drawn hardware

@MainActor
private enum Hardware {
    static let needleRest: CGFloat = 0.82              // radians, far left (at rest)
    static func needleAngle(_ level: Double) -> CGFloat { CGFloat(0.72 - level * 1.44) } // 0 = −20 dB … 1 = +3 dB

    /// The fine dot mesh in front of a fluorescent display.
    static let meshColor: CGColor = {
        let tile = NSImage(size: NSSize(width: 3, height: 3), flipped: false) { _ in
            NSColor(white: 0, alpha: 0.35).setFill()
            NSRect(x: 0, y: 0, width: 3, height: 1).fill()
            NSRect(x: 0, y: 0, width: 1, height: 3).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    static func image(size: CGSize, scale: CGFloat, draw: @escaping (CGContext) -> Void) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // Faceplate: dark brushed aluminum, bevelled edges, screws in the corners.
    static func faceplate(_ size: CGSize) {
        let r = NSRect(origin: .zero, size: size)
        let plate = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSGradient(colors: [NSColor(white: 0.23, alpha: 0.97), NSColor(white: 0.14, alpha: 0.97), NSColor(white: 0.18, alpha: 0.97)],
                   atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: plate, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0.0, to: size.height, by: 1) { // brushing
            NSColor(white: Bool.random(using: &rng) ? 1 : 0, alpha: Double.random(in: 0.01...0.045, using: &rng)).setFill()
            NSRect(x: 0, y: y, width: size.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.18).setStroke()
        plate.lineWidth = 1
        plate.stroke()
        for p in [CGPoint(x: 12, y: 12), CGPoint(x: size.width - 12, y: 12),
                  CGPoint(x: 12, y: size.height - 12), CGPoint(x: size.width - 12, y: size.height - 12)] {
            let screw = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
            NSGradient(starting: NSColor(white: 0.7, alpha: 1), ending: NSColor(white: 0.3, alpha: 1))?
                .draw(in: NSBezierPath(ovalIn: screw), angle: -60)
            NSColor(white: 0.12, alpha: 0.9).setStroke()
            let slot = NSBezierPath()
            slot.move(to: NSPoint(x: p.x - 3, y: p.y + 1.5)); slot.line(to: NSPoint(x: p.x + 3, y: p.y - 1.5))
            slot.lineWidth = 1.2
            slot.stroke()
        }
    }

    static func header(_ r: CGRect, brand: String, model: String) {
        let brandText = NSAttributedString(string: brand, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .heavy), .kern: 4, .foregroundColor: NSColor(white: 0.86, alpha: 1)])
        brandText.draw(at: NSPoint(x: r.minX, y: r.maxY - 18))
        NSAttributedString(string: model, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .kern: 1.6, .foregroundColor: NSColor(white: 0.62, alpha: 1)])
            .draw(at: NSPoint(x: r.minX, y: r.maxY - 32))
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: 1).fill()
        NSColor(white: 0, alpha: 0.4).setFill()
        NSRect(x: r.minX, y: r.minY + 1, width: r.width, height: 1).fill()
    }

    static func glass(_ r: CGRect) {
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10).fill() // bezel
        NSGradient(colors: [NSColor(red: 0.02, green: 0.07, blue: 0.08, alpha: 1), NSColor(red: 0.01, green: 0.03, blue: 0.04, alpha: 1)])?
            .draw(in: path, angle: -90)
        NSColor(white: 1, alpha: 0.08).setStroke()
        path.stroke()
    }

    static func label(_ text: String, centeredAt p: CGPoint, size: CGFloat = 7.5, alpha: CGFloat = 0.62) {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold), .kern: 1.2, .foregroundColor: NSColor(white: 0.85, alpha: alpha)])
        let w = s.size()
        s.draw(at: NSPoint(x: p.x - w.width / 2, y: p.y - w.height / 2))
    }

    static func deck(size: CGSize, layout l: DeckLayout, scale: CGFloat) -> CGImage? {
        image(size: size, scale: scale) { _ in
            faceplate(size)
            header(l.header, brand: "HIMAWARI", model: "COMPACT DISC PLAYER   HD-2160")
            glass(l.display)
            // Disc tray: a slot with a bevel, an eject label and a lit "DISC" lamp.
            let tray = NSBezierPath(roundedRect: l.tray, xRadius: 3, yRadius: 3)
            NSColor(white: 0.03, alpha: 1).setFill(); tray.fill()
            NSColor(white: 1, alpha: 0.14).setStroke(); tray.stroke()
            label("DISC", centeredAt: CGPoint(x: l.tray.maxX - 22, y: l.tray.minY - 9))
            amberLamp(CGPoint(x: l.tray.maxX - 42, y: l.tray.minY - 9))
            label("OPEN / CLOSE", centeredAt: CGPoint(x: l.tray.minX + 34, y: l.tray.minY - 9))
            // Transport buttons.
            let symbols = ["backward.end.fill", "playpause.fill", "forward.end.fill", "stop.fill", "eject.fill"]
            for (rect, name) in zip(l.buttonRects, symbols) {
                let b = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                NSGradient(colors: [NSColor(white: 0.42, alpha: 1), NSColor(white: 0.2, alpha: 1)])?.draw(in: b, angle: -90)
                NSColor(white: 0, alpha: 0.7).setStroke(); b.stroke()
                NSColor(white: 1, alpha: 0.18).setFill()
                NSRect(x: rect.minX + 3, y: rect.maxY - 2, width: rect.width - 6, height: 1).fill()
                symbol(name, in: rect)
            }
            // Power switch and headphone jack.
            let powerY = l.column.minY + 22
            let power = NSRect(x: l.column.minX, y: powerY - 10, width: 44, height: 20)
            NSGradient(colors: [NSColor(white: 0.4, alpha: 1), NSColor(white: 0.18, alpha: 1)])?
                .draw(in: NSBezierPath(roundedRect: power, xRadius: 4, yRadius: 4), angle: -90)
            label("POWER", centeredAt: CGPoint(x: power.midX, y: power.maxY + 9))
            greenLamp(CGPoint(x: power.maxX + 12, y: power.midY))
            let jack = CGPoint(x: l.column.maxX - 14, y: powerY)
            NSColor(white: 0.55, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: jack.x - 9, y: jack.y - 9, width: 18, height: 18)).fill()
            NSColor(white: 0.02, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: jack.x - 4.5, y: jack.y - 4.5, width: 9, height: 9)).fill()
            label("PHONES", centeredAt: CGPoint(x: jack.x, y: jack.y + 17))
            // Jog wheel well.
            NSColor(white: 0, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: l.jog.insetBy(dx: -5, dy: -5)).fill()
            label("JOG", centeredAt: CGPoint(x: l.jog.midX, y: l.jog.minY - 14))
        }
    }

    static func analyzer(size: CGSize, layout l: AnalyzerLayout, scale: CGFloat) -> CGImage? {
        image(size: size, scale: scale) { _ in
            faceplate(size)
            header(l.header, brand: "HIMAWARI", model: "STEREO LEVEL ANALYZER   SA-10")
            for (i, face) in l.meters.enumerated() { vuFace(face, channel: i == 0 ? "L" : "R") }
            glass(l.spectrumGlass)
            let bands = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
            let step = l.labels.width / CGFloat(bands.count)
            for (i, b) in bands.enumerated() {
                let s = NSAttributedString(string: b, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .medium),
                                                                  .foregroundColor: NowPlayingSides.vfd.withAlphaComponent(0.45)])
                let w = s.size().width
                s.draw(at: NSPoint(x: l.labels.minX + step * (CGFloat(i) + 0.5) - w / 2, y: l.labels.minY))
            }
            for (rect, name) in l.knobs { knob(rect, label: name, pointer: GearControl(knob: name) == nil) }
        }
    }

    /// An amber-backlit analog VU meter face (the needle is a separate layer).
    static func vuFace(_ r: CGRect, channel: String) {
        NSColor(white: 0, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
        let face = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGradient(colors: [NSColor(red: 1, green: 0.9, blue: 0.66, alpha: 1), NSColor(red: 0.93, green: 0.72, blue: 0.4, alpha: 1)])?
            .draw(in: face, relativeCenterPosition: NSPoint(x: 0, y: -0.2))
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        let pivot = CGPoint(x: r.midX, y: r.minY - r.height * 0.28)
        let radius = r.height * 0.98
        let ink = NSColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 0.9)
        // Scale arc, the red zone above 0 dB, tick marks and numbers.
        func point(_ angle: CGFloat, _ rad: CGFloat) -> CGPoint {
            CGPoint(x: pivot.x - sin(angle) * rad, y: pivot.y + cos(angle) * rad)
        }
        let marks: [(Double, String)] = [(0, "20"), (0.28, "10"), (0.42, "7"), (0.53, "5"), (0.64, "3"), (0.7, "2"),
                                          (0.76, "1"), (0.82, "0"), (0.88, "1"), (0.94, "2"), (1, "3")]
        let arc = NSBezierPath()
        arc.appendArc(withCenter: pivot, radius: radius, startAngle: 90 + 0.72 * 180 / .pi, endAngle: 90 - 0.72 * 180 / .pi, clockwise: true)
        ink.setStroke(); arc.lineWidth = 1.2; arc.stroke()
        let red = NSBezierPath()
        red.appendArc(withCenter: pivot, radius: radius + 2.5, startAngle: 90 + needleAngle(0.82) * 180 / .pi,
                      endAngle: 90 + needleAngle(1) * 180 / .pi, clockwise: true)
        NSColor(red: 0.82, green: 0.12, blue: 0.1, alpha: 0.9).setStroke(); red.lineWidth = 4.5; red.stroke()
        for (level, text) in marks {
            let a = needleAngle(level)
            let t = NSBezierPath()
            t.move(to: point(a, radius)); t.line(to: point(a, radius + 7))
            (level > 0.82 ? NSColor(red: 0.75, green: 0.1, blue: 0.08, alpha: 1) : ink).setStroke()
            t.lineWidth = 1.2; t.stroke()
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                                                                  .foregroundColor: level > 0.82 ? NSColor(red: 0.75, green: 0.1, blue: 0.08, alpha: 1) : ink])
            let p = point(a, radius + 14), w = s.size()
            s.draw(at: NSPoint(x: p.x - w.width / 2, y: p.y - w.height / 2))
        }
        let vu = NSAttributedString(string: "VU", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: ink])
        vu.draw(at: NSPoint(x: r.midX - vu.size().width / 2, y: r.minY + r.height * 0.2))
        let ch = NSAttributedString(string: channel, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: ink])
        ch.draw(at: NSPoint(x: r.minX + 10, y: r.minY + 8))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func knob(_ r: CGRect, label name: String, pointer drawPointer: Bool = true) {
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -4).offsetBy(dx: 0, dy: -1)).fill() // shadow
        NSGradient(colors: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.25, alpha: 1)])?
            .draw(in: NSBezierPath(ovalIn: r), angle: -70)
        NSGradient(colors: [NSColor(white: 0.36, alpha: 1), NSColor(white: 0.5, alpha: 1)])?
            .draw(in: NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.14, dy: r.width * 0.14)), angle: -70)
        let c = CGPoint(x: r.midX, y: r.midY), a = CGFloat.pi * 0.25
        if drawPointer { // the VOLUME knob gets a live pointer layer instead
            let pointer = NSBezierPath()
            pointer.move(to: CGPoint(x: c.x - sin(a) * r.width * 0.12, y: c.y + cos(a) * r.width * 0.12))
            pointer.line(to: CGPoint(x: c.x - sin(a) * r.width * 0.36, y: c.y + cos(a) * r.width * 0.36))
            NSColor(white: 0.95, alpha: 0.9).setStroke(); pointer.lineWidth = 2; pointer.stroke()
        }
        for i in 0...10 { // scale dots
            let t = -0.75 * CGFloat.pi + CGFloat(i) * 0.15 * CGFloat.pi
            let p = CGPoint(x: c.x - sin(t) * (r.width / 2 + 6), y: c.y + cos(t) * (r.width / 2 + 6))
            NSColor(white: 0.8, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)).fill()
        }
        label(name, centeredAt: CGPoint(x: r.midX, y: r.minY - 12))
    }

    static func symbol(_ name: String, in rect: CGRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.9, alpha: 0.85)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    static func amberLamp(_ p: CGPoint) { lamp(p, NowPlayingSides.amber) }
    static func greenLamp(_ p: CGPoint) { lamp(p, NSColor(red: 0.3, green: 1, blue: 0.45, alpha: 1)) }
    private static func lamp(_ p: CGPoint, _ color: NSColor) {
        color.withAlphaComponent(0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    }

    /// The jog wheel: knurled rim, brushed face, a finger dimple (so you can see it turn).
    static func jogWheel(diameter d: CGFloat, scale: CGFloat) -> CGImage? {
        image(size: CGSize(width: d, height: d), scale: scale) { _ in
            let r = NSRect(x: 0, y: 0, width: d, height: d)
            NSGradient(colors: [NSColor(white: 0.5, alpha: 1), NSColor(white: 0.16, alpha: 1)])?.draw(in: NSBezierPath(ovalIn: r), angle: -60)
            let c = CGPoint(x: d / 2, y: d / 2)
            for i in 0..<90 { // knurling
                let a = CGFloat(i) / 90 * 2 * .pi
                let k = NSBezierPath()
                k.move(to: CGPoint(x: c.x + cos(a) * d * 0.44, y: c.y + sin(a) * d * 0.44))
                k.line(to: CGPoint(x: c.x + cos(a) * d * 0.5, y: c.y + sin(a) * d * 0.5))
                NSColor(white: i % 2 == 0 ? 0.08 : 0.6, alpha: 0.5).setStroke()
                k.lineWidth = 1; k.stroke()
            }
            let face = r.insetBy(dx: d * 0.08, dy: d * 0.08)
            NSGradient(colors: [NSColor(white: 0.28, alpha: 1), NSColor(white: 0.44, alpha: 1), NSColor(white: 0.26, alpha: 1)],
                       atLocations: [0, 0.5, 1], colorSpace: .sRGB)?.draw(in: NSBezierPath(ovalIn: face), angle: -45)
            for ring in stride(from: d * 0.08, to: d * 0.42, by: 2.5) { // concentric brushing
                NSColor(white: 1, alpha: 0.035).setStroke()
                NSBezierPath(ovalIn: NSRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)).stroke()
            }
            let dimple = NSRect(x: c.x + d * 0.2 - d * 0.07, y: c.y + d * 0.12 - d * 0.07, width: d * 0.14, height: d * 0.14)
            NSGradient(colors: [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.4, alpha: 1)])?.draw(in: NSBezierPath(ovalIn: dimple), angle: -60)
        }
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

    init?(knob name: String) {
        switch name {
        case "VOLUME": self = .volume
        case "BASS": self = .bass
        case "TREBLE": self = .treble
        default: return nil
        }
    }
}
