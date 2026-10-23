import AppKit
import HimawariKit
import QuartzCore

/// For songs with no motion artwork (and no YouTube video): the album cover on the style's
/// media (a CD, a record on a turntable, or a cassette) turning slowly over a soft glow in the
/// cover's colours, with little animals and chibi characters running along the bottom. All
/// Core Animation, drawn by the window server at a low frame rate; everything stops when the
/// music (or the wallpaper) pauses.
@MainActor
final class MusicScene: NSView {
    /// Names this view's click catchers. Not ObjectIdentifier: a view rebuilt after a screen change
    /// can reuse a freed one's address, and its catchers would keep pointing at the old view.
    let catcherKey = UUID().uuidString
    private let stage = CALayer()      // everything; its clock is what pausing stops
    private let discStage = CALayer() // the discs and their luster, above the side gear
    private let ambient = AmbientLayer()
    private var holder = CALayer()     // carries the media and its shadow; slides when the song changes
    /// What turns: the CD or the record, or the cassette's two hubs.
    private var spinners: [CALayer] = []
    private var label: CALayer?        // the cover on the record's label or the cassette's
    private var packs: [CALayer] = []  // the cassette's tape: the left reel empties, the right fills
    private let tonearm = CALayer()    // the record player's arm: it travels in through the song
    private let sheen = CAGradientLayer()
    private let runners = CALayer()
    private let topInset: CGFloat, bottomInset: CGFloat
    private var cover: CGImage?
    private var print: CGImage?   // the cover wrapped around the disc (DiscPrint), once it's made
    private var printJob = 0      // the newest one wins if covers change quickly
    private var changing = false          // a change of discs is under way
    private var changes = 0
    private var queued: DiscDirection?    // …and another song came meanwhile
    private(set) var palette: AmbientPalette
    /// The square the media sits in, between the side panels (this view's coordinates, y up).
    private(set) var discRect = CGRect.zero
    /// The media itself: the disc's square, or the cassette inside it.
    private(set) var mediaRect = CGRect.zero
    var mediaIsRound: Bool { media != .cassette }

    /// The look: switching rebuilds the gear and the media; the song and its place stay.
    var style: Skin = Styles.shared.current {
        didSet {
            guard style != oldValue else { return }
            media = Themes.media(style.era)
            print = nil // a CD's print is made again for it (the cover may have changed meanwhile)
            sides.style = style
            layoutScene(force: true)
        }
    }
    private(set) var media: MediaKind = Themes.media(Styles.shared.current.era)

    var running = true {
        didSet {
            guard running != oldValue else { return }
            updateClock()
            if running { followSong(force: true) } // the clock stood still: catch up with the song
        }
    }
    private let sides = NowPlayingSides(frame: .zero)
    var meterSource: AudioLevels? { didSet { sides.meterSource = meterSource } }
    func levelsChanged() { sides.levelsChanged() }
    /// The side gear beside the disc (for the click catchers).
    var gear: NowPlayingSides? { sides.isHidden ? nil : sides }
    private var song: SongInfo?
    /// Where the tonearm and the tape were last sent: (song position, at this time).
    private var followed: (title: String, duration: Double, playing: Bool, position: Double, at: CFTimeInterval)?

    // MARK: Spinning the disc by hand

    private var grabbedAt: [CGFloat] = []
    /// Cassette hubs turn a little faster than your hand (they're small).
    private var turnRatio: CGFloat { media == .cassette ? 2 : 1 }

    /// You grabbed the disc: it stops turning by itself, right where it was.
    func grabDisc() {
        grabbedAt = spinners.map { ($0.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (spinner, angle) in zip(spinners, grabbedAt) {
            spinner.removeAnimation(forKey: "spin")
            spinner.removeAnimation(forKey: "spinUp")
            spinner.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        }
        CATransaction.commit()
    }

    /// …and it follows your hand, `angle` radians (counterclockwise) from where you grabbed it.
    func turnDisc(by angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (spinner, start) in zip(spinners, grabbedAt) {
            spinner.transform = CATransform3DMakeRotation(start + angle * turnRatio, 0, 0, 1)
        }
        CATransaction.commit()
    }

    /// Let go: it spins on by itself from where you left it.
    func releaseDisc() {
        spinners.forEach(addSpin)
    }

    func setSong(_ info: SongInfo?, animating: Bool) {
        sides.isHidden = info == nil
        sides.animating = animating
        if let info { sides.show(info) }
        if info?.title != song?.title || info?.artist != song?.artist { song = info; writeTapeLabel() }
        song = info
        followSong(force: false)
    }
    /// Off in Battery Saver: the CD still turns (slowly), nobody runs around.
    var lively = true { didSet { if lively != oldValue { layoutScene(force: true) } } }

    init(frame: NSRect, artwork: NSImage, topInset: CGFloat, bottomInset: CGFloat) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        cover = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        palette = cover.flatMap { FrameSampler($0) }.map(AmbientPalette.from) ?? .neutral
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(stage)
        stage.addSublayer(ambient)
        ambient.show(palette)

        discStage.addSublayer(holder) // the real disc is built in layoutScene, once its size is known
        // The CD's luster: rainbow sheen with two bright streaks, where the light catches it.
        // It belongs to the light, not the disc, so it stays put while the disc turns under it.
        sheen.type = .conic
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        discStage.addSublayer(sheen)
        discStage.addSublayer(tonearm)
        stage.addSublayer(runners)
        sides.frame = bounds
        sides.autoresizingMask = [.width, .height]
        sides.isHidden = true
        addSubview(sides)
        // The discs travel above the side gear (they cross it when CDs change); at rest the
        // disc sits between the panels, so nothing is hidden.
        discStage.zPosition = 10
        layer?.addSublayer(discStage)
        layoutScene(force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A new song: like a disc changer, the old CD slides out to the left, still turning,
    /// and the new one slides in from the right with a little extra spin as it settles.
    /// While nobody can see it (desktop covered, screen locked), just a quick cross-fade.
    func setArtwork(_ artwork: NSImage, direction: DiscDirection = .forward) {
        cover = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        palette = cover.flatMap { FrameSampler($0) }.map(AmbientPalette.from) ?? .neutral
        ambient.show(palette)
        guard discRect.width > 0 else { spinners.first?.contents = cover; return }
        // Skipping again mid-change: let this change finish, then go straight to the newest
        // song (two changes at once would fight over the same disc).
        guard !changing else { queued = direction; return }
        changeDiscs(direction)
    }

    /// The new disc comes in only once its print is ready (a few hundredths of a second),
    /// so what slides in is the finished disc.
    private func changeDiscs(_ direction: DiscDirection) {
        changing = true
        changes += 1
        let change = changes
        // Safety: if this change never got going (its print was superseded by a resize), don't
        // stay "busy" and ignore every later song.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.changing, self.changes == change else { return }
            self.changeFinished()
        }
        guard media == .cd else { print = nil; swapDisc(direction); return } // records and tapes show the cover as it is
        renderPrint(side: discRect.width) { [weak self] image in
            guard let self else { return }
            // Switched to a record or a cassette meanwhile: it already shows the new cover.
            guard self.media == .cd else { self.print = nil; self.changeFinished(); return }
            self.print = image
            self.swapDisc(direction)
        }
    }

    /// A change of discs just finished: if more songs went by meanwhile, show the latest.
    private func changeFinished() {
        changing = false
        guard let next = queued else { return }
        queued = nil
        changeDiscs(next)
    }

    /// A new scene (coming from Apple Music's animation or your own wallpaper): its disc
    /// slides in from the side we're heading toward while the scene fades in.
    func arrive(from direction: DiscDirection) {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            animator().alphaValue = 1
        }
        guard running, discRect.width > 0 else { return }
        let start = direction == .forward ? bounds.width + discRect.width / 2 + 60 : -discRect.width / 2 - 60
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = start
        slide.toValue = discRect.midX
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.9
        grow.toValue = 1
        let enter = CAAnimationGroup()
        enter.animations = [slide, grow]
        enter.duration = 1.0
        enter.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.3, 1)
        enter.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        holder.add(enter, forKey: "in")
    }

    /// The scene is going away (the next song has Apple Music's animation, or the music
    /// stopped): the CD slides off to the left, then the whole scene fades, revealing what's
    /// already playing underneath. While hidden, just the fade.
    func leave(then done: @escaping () -> Void) {
        let fade = { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                self?.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
        }
        guard running, discRect.width > 0 else { fade(); return }
        let exit = CABasicAnimation(keyPath: "position.x")
        exit.toValue = -discRect.width / 2 - 60
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.9
        let out = CAAnimationGroup()
        out.animations = [exit, shrink]
        out.duration = 0.8
        out.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.9, 0.5)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        out.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        holder.add(out, forKey: "leave")
        for l in [sheen, tonearm] as [CALayer] { // the luster goes with the light on the disc; the arm lifts away
            let dim = CABasicAnimation(keyPath: "opacity")
            dim.toValue = 0
            dim.duration = 0.3
            dim.fillMode = .forwards
            dim.isRemovedOnCompletion = false
            l.add(dim, forKey: "leave")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { fade() }
    }

    /// The same song's cover, sharper: print it and put it on the disc that's there, no change of discs.
    func repaint(with artwork: NSImage) {
        cover = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        palette = cover.flatMap { FrameSampler($0) }.map(AmbientPalette.from) ?? .neutral
        ambient.show(palette)
        guard discRect.width > 0 else { return }
        guard media == .cd else { print = nil; label?.contents = cover; return }
        renderPrint(side: discRect.width) { [weak self] image in
            guard let self, self.media == .cd, let disc = self.spinners.first else { return }
            self.print = image
            self.showPrint(on: disc)
        }
    }

    private func swapDisc(_ direction: DiscDirection) {
        let oldHolder = holder
        let center = CGPoint(x: discRect.midX, y: discRect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let newHolder = makeMedia()
        discStage.insertSublayer(newHolder, above: oldHolder)
        spinners.forEach(addSpin)
        CATransaction.commit()
        holder = newHolder
        followSong(force: true)

        let now = newHolder.convertTime(CACurrentMediaTime(), from: nil) // the stage's own clock (it pauses)
        guard running else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.4
            newHolder.add(fade, forKey: "in")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                oldHolder.removeFromSuperlayer()
                self?.changeFinished()
            }
            return
        }
        // All the way: off the left edge, and in from beyond the right one.
        // Forward: out to the left, in from the right. Back (Previous): the other way round.
        let left = -discRect.width / 2 - 60, right = bounds.width + discRect.width / 2 + 60
        let (exitX, entryX) = direction == .forward ? (left, right) : (right, left)
        let rate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) // a short move: make it smooth

        // Out: accelerate away to the left, shrinking and fading.
        let outMove = CABasicAnimation(keyPath: "position.x")
        outMove.toValue = exitX
        let outScale = CABasicAnimation(keyPath: "transform.scale")
        outScale.toValue = 0.9
        let outFade = CAKeyframeAnimation(keyPath: "opacity")
        outFade.values = [1, 1, 0]
        outFade.keyTimes = [0, 0.45, 1]
        let out = CAAnimationGroup()
        out.animations = [outMove, outScale, outFade]
        out.duration = 0.8
        out.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.9, 0.5)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        out.preferredFrameRateRange = rate
        oldHolder.add(out, forKey: "out")

        // In: glide in from the right and settle (a soft overshoot-free ease-out).
        let inMove = CABasicAnimation(keyPath: "position.x")
        inMove.fromValue = entryX
        inMove.toValue = center.x
        let inScale = CABasicAnimation(keyPath: "transform.scale")
        inScale.fromValue = 0.9
        inScale.toValue = 1
        let inFade = CAKeyframeAnimation(keyPath: "opacity")
        inFade.values = [0, 1, 1]
        inFade.keyTimes = [0, 0.4, 1]
        let enter = CAAnimationGroup()
        enter.animations = [inMove, inScale, inFade]
        enter.beginTime = now + 0.35
        enter.duration = 1.0
        enter.fillMode = .backwards // invisible off to the right until it starts
        enter.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.85, 0.3, 1)
        enter.preferredFrameRateRange = rate
        newHolder.add(enter, forKey: "in")

        // …and it arrives spinning a little faster, slowing to the normal speed.
        for spinner in spinners {
            let spinUp = CABasicAnimation(keyPath: "transform.rotation.z")
            // Additive and ending at 0, so removing it when it finishes changes nothing: an extra turn
            // that winds down (it used to end 2.6 rad off, and the print jumped ~150° at the end).
            spinUp.fromValue = direction == .forward ? 2.6 : -2.6 // going back, it rewinds a little as it arrives
            spinUp.toValue = 0
            spinUp.isAdditive = true
            spinUp.fillMode = .backwards
            spinUp.beginTime = now + 0.35
            spinUp.duration = 1.4
            spinUp.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spinUp.preferredFrameRateRange = rate
            spinner.add(spinUp, forKey: "spinUp")
        }

        // The luster belongs to the light, not the disc: dim it while the discs move.
        let dip = CAKeyframeAnimation(keyPath: "opacity")
        dip.values = [1, 0, 0, 1]
        dip.keyTimes = [0, 0.2, 0.7, 1]
        dip.duration = 1.2
        dip.preferredFrameRateRange = rate
        sheen.add(dip, forKey: "dip")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            oldHolder.removeFromSuperlayer()
            self?.changeFinished()
        }
    }

    /// The CD's layout, as fractions of its radius.
    private enum CD {
        static let hole: CGFloat = 0.09       // the center hole
        static let print: CGFloat = 0.22      // one silver ring out to here, then the picture
        static let luster: CGFloat = 0.43     // the shine fades out by here
    }

    /// The record's layout, as fractions of the square's half width.
    enum Record {
        static let vinyl: CGFloat = 0.955     // the record, inside the platter's rim
        static let label: CGFloat = 0.34      // the paper label (the cover)
        static let leadIn: CGFloat = 0.93     // where the stylus starts…
        static let runOut: CGFloat = 0.4      // …and where the song ends
        static let pivot = CGPoint(x: 0.82, y: 0.82) // the tonearm's pivot, in the square's corner
        static let arm: CGFloat = 1.2         // pivot to stylus
        static let rest: CGFloat = -0.46 * .pi // the arm parked just off the record
    }

    /// The tonearm's angle (radians, from +x) that puts the stylus `radius` from the record's
    /// centre (both in half widths of the square). Internal for the tests.
    nonisolated static func tonearmAngle(forRadius radius: CGFloat) -> CGFloat {
        // From pointing almost straight down (outside the record) round to pointing inward: the
        // stylus's distance from the centre only shrinks, so halve the range until it's found.
        var lo: CGFloat = -0.45 * .pi, hi: CGFloat = -0.75 * .pi
        func reach(_ a: CGFloat) -> CGFloat {
            hypot(Record.pivot.x + Record.arm * cos(a), Record.pivot.y + Record.arm * sin(a))
        }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if reach(mid) > radius { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// The arm's angle `fraction` (0…1) of the way through the song: the stylus moves inward
    /// evenly across the grooves.
    nonisolated static func tonearmAngle(fraction: Double) -> CGFloat {
        let f = CGFloat(min(max(fraction, 0), 1))
        return tonearmAngle(forRadius: Record.leadIn + (Record.runOut - Record.leadIn) * f)
    }

    /// One piece of media, in a holder that carries its shadow: the CD, the record on its
    /// platter, or the cassette. Sets `spinners`, `label` and `packs` to its parts.
    private func makeMedia() -> CALayer {
        packs = []
        label = nil
        tapeText = nil
        switch media {
        case .cd:
            let (holder, disc) = makeDisc(side: discRect.width)
            spinners = [disc]
            return holder
        case .record: return makeRecord(side: discRect.width)
        case .cassette: return makeCassette()
        }
    }

    /// One CD: the picture printed on it (the part that spins), a single silver ring around
    /// the center, and a real hole you can see through. The ring looks the same at every
    /// angle, so only the picture needs to turn.
    private func makeDisc(side: CGFloat) -> (holder: CALayer, disc: CALayer) {
        let r = side / 2, c = CGPoint(x: r, y: r)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let holder = makeHolder(bounds, shadow: Self.ring(c, outer: r, inner: r * CD.hole)) // no shadow in the hole

        let mirror = CAGradientLayer() // brushed silver, catching the light unevenly
        mirror.type = .conic
        mirror.startPoint = CGPoint(x: 0.5, y: 0.5)
        mirror.endPoint = CGPoint(x: 0.5, y: 1)
        mirror.colors = [0.82, 0.58, 0.95, 0.62, 0.88, 0.55, 0.93, 0.6, 0.82].map { NSColor(white: $0, alpha: 1).cgColor }
        mirror.frame = bounds
        mirror.mask = Self.shape(Self.ring(c, outer: r * CD.print, inner: r * CD.hole), in: bounds)

        let edges = CAShapeLayer()   // the hole's edge and the ring's edge
        let lines = CGMutablePath()
        for f in [CD.hole, CD.print] {
            lines.addEllipse(in: CGRect(x: c.x - r * f, y: c.y - r * f, width: 2 * r * f, height: 2 * r * f))
        }
        edges.path = lines
        edges.fillColor = nil
        edges.strokeColor = NSColor(white: 1, alpha: 0.32).cgColor
        edges.lineWidth = 1

        let disc = CALayer()
        disc.frame = bounds
        showPrint(on: disc)
        disc.contentsScale = window?.backingScaleFactor ?? 2
        disc.mask = Self.shape(Self.ring(c, outer: r, inner: r * CD.print), in: bounds)

        for l in [mirror, edges, disc] as [CALayer] { holder.addSublayer(l) }
        return (holder, disc)
    }

    private func makeHolder(_ bounds: CGRect, shadow: CGPath) -> CALayer {
        let holder = CALayer()
        holder.bounds = bounds
        holder.position = CGPoint(x: discRect.midX, y: discRect.midY)
        holder.shadowColor = NSColor.black.cgColor
        holder.shadowOpacity = 0.55
        holder.shadowRadius = 30
        holder.shadowOffset = CGSize(width: 0, height: -12)
        holder.shadowPath = shadow
        return holder
    }

    /// A record on the turntable's platter: black vinyl with its grooves catching the light, the
    /// cover as its paper label, and the spindle. The platter's rim, with its strobe dots, stays
    /// still; the record and its label turn.
    private func makeRecord(side: CGFloat) -> CALayer {
        let r = side / 2, c = CGPoint(x: r, y: r)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let scale = window?.backingScaleFactor ?? 2
        let holder = makeHolder(bounds, shadow: CGPath(ellipseIn: bounds, transform: nil))
        let platter = CALayer()
        platter.frame = bounds
        platter.contents = Self.platterImage(side: side, scale: scale, metal: style.colors.media)
        platter.contentsScale = scale
        holder.addSublayer(platter)

        let record = CALayer()
        record.frame = bounds
        record.contents = Self.vinylImage(side: side, scale: scale)
        record.contentsScale = scale
        let labelSide = side * Record.label
        let paper = CALayer()
        paper.frame = CGRect(x: c.x - labelSide / 2, y: c.y - labelSide / 2, width: labelSide, height: labelSide)
        paper.contents = cover
        paper.contentsGravity = .resizeAspectFill
        paper.masksToBounds = true
        paper.cornerRadius = labelSide / 2
        paper.borderColor = NSColor(white: 0, alpha: 0.4).cgColor
        paper.borderWidth = 1
        record.addSublayer(paper)
        let spindle = CALayer()
        let s = max(side * 0.022, 5)
        spindle.frame = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
        spindle.cornerRadius = s / 2
        spindle.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        spindle.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        spindle.borderWidth = 0.5
        record.addSublayer(spindle)
        holder.addSublayer(record)
        spinners = [record]
        label = paper
        return holder
    }

    /// Where the cassette and its case sit in the square (fractions of its side): the case, with
    /// the whole cover on its card, stands behind; the tape lies in front, over the case's foot.
    enum Tape {
        static let caseRect = CGRect(x: 0.18, y: 0.445, width: 0.535, height: 0.535)
        static let tapeRect = CGRect(x: 0.13, y: 0, width: 0.8, height: 0.8 * 63.8 / 100)
    }

    /// A cassette in front of its open case: the whole cover on the case's card, and the tape
    /// with the song written on its label, its tape on two reels whose hubs turn.
    private func makeCassette() -> CALayer {
        let side = discRect.width
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let scale = window?.backingScaleFactor ?? 2
        func scaled(_ r: CGRect) -> CGRect { CGRect(x: r.minX * side, y: r.minY * side, width: r.width * side, height: r.height * side) }
        let caseRect = scaled(Tape.caseRect), tapeRect = scaled(Tape.tapeRect)
        let shadow = CGMutablePath()
        shadow.addRoundedRect(in: caseRect.insetBy(dx: -side * 0.02, dy: -side * 0.02), cornerWidth: side * 0.015, cornerHeight: side * 0.015)
        shadow.addRoundedRect(in: tapeRect, cornerWidth: tapeRect.height * 0.06, cornerHeight: tapeRect.height * 0.06)
        let holder = makeHolder(bounds, shadow: shadow)
        func picture(_ frame: CGRect, in parent: CALayer, _ draw: @escaping () -> Void) {
            let l = CALayer()
            l.frame = frame
            l.contents = Paint.image(size: frame.size, scale: scale) { _ in draw() }
            l.contentsScale = scale
            parent.addSublayer(l)
        }

        // The case: smoked plastic round the card, the cover whole on the card, and a gloss.
        let caseFrame = caseRect.insetBy(dx: -side * 0.02, dy: -side * 0.02)
        picture(caseFrame, in: holder) { CassetteTheme.caseBack(CGRect(origin: .zero, size: caseFrame.size), card: side * 0.02) }
        let card = CALayer()
        card.frame = caseRect
        card.contents = cover
        card.contentsGravity = .resizeAspectFill
        card.masksToBounds = true
        card.cornerRadius = side * 0.004
        holder.addSublayer(card)
        label = card
        picture(caseFrame, in: holder) { CassetteTheme.caseFront(CGRect(origin: .zero, size: caseFrame.size), card: side * 0.02) }

        // The tape.
        let tape = CALayer()
        tape.frame = tapeRect
        holder.addSublayer(tape)
        let size = tapeRect.size, local = CGRect(origin: .zero, size: size)
        let g = CassetteTheme.Big(size: size)
        let skin = style
        picture(local, in: tape) {
            CassetteTheme.cassette(local, reels: g.reels, full: g.full, skin, small: false)
            CassetteTheme.ruledLabel(local)
        }
        // The song, written on the label above the window, the artist below it.
        let ink = NSColor(red: 0.12, green: 0.16, blue: 0.42, alpha: 0.92).cgColor // ballpoint blue
        let area = CassetteTheme.labelArea(local)
        let title = CATextLayer(), artist = CATextLayer()
        for (text, y0, y1, fontSize) in [(title, g.window.maxY + size.height * 0.035, area.maxY, size.height * 0.075),
                                         (artist, area.minY, g.window.minY - size.height * 0.035, size.height * 0.055)] {
            text.frame = CGRect(x: area.minX + size.width * 0.05, y: y0, width: area.width - size.width * 0.1, height: y1 - y0)
            text.font = NSFont(name: "MarkerFelt-Wide", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            text.fontSize = fontSize
            text.foregroundColor = ink
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = scale
            tape.addSublayer(text)
        }
        tapeText = (title, artist)
        writeTapeLabel()

        // Cut away for the window and the hub holes: the tape and hubs show through.
        picture(local, in: tape) { CassetteTheme.inside(g) }
        let inside = CALayer()
        inside.frame = local
        inside.mask = Self.shape(g.openings, in: local)
        tape.addSublayer(inside)
        let packImage = Paint.image(size: CGSize(width: g.full * 2, height: g.full * 2), scale: scale) { _ in CassetteTheme.pack(radius: g.full) }
        packs = g.reels.map { c in
            let pack = CALayer()
            pack.bounds = CGRect(x: 0, y: 0, width: g.full * 2, height: g.full * 2)
            pack.position = c
            pack.contents = packImage
            pack.contentsScale = scale
            inside.addSublayer(pack)
            return pack
        }
        packHub = g.spool / g.full
        let hubImage = Paint.image(size: CGSize(width: g.hubD, height: g.hubD), scale: scale) { _ in CassetteTheme.hub(diameter: g.hubD) }
        spinners = g.reels.map { c in
            let h = CALayer()
            h.frame = CGRect(x: c.x - g.hubD / 2, y: c.y - g.hubD / 2, width: g.hubD, height: g.hubD)
            h.contents = hubImage
            h.contentsScale = scale
            inside.addSublayer(h)
            return h
        }
        picture(local, in: tape) { CassetteTheme.glass(g) }
        return holder
    }

    /// The song and artist written on the cassette's label.
    private var tapeText: (title: CATextLayer, artist: CATextLayer)?

    private func writeTapeLabel() {
        guard let (title, artist) = tapeText else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        title.string = song?.title ?? ""
        artist.string = song?.artist ?? ""
        CATransaction.commit()
    }

    /// An empty reel's size as a fraction of a full one's.
    private var packHub: CGFloat = 0.4

    /// The tonearm's picture, pointing along +x from its pivot at (`back`, height / 2).
    private static func tonearmImage(length: CGFloat, scale: CGFloat) -> (CGImage?, back: CGFloat, size: CGSize) {
        let back = length * 0.22, w = max(length * 0.09, 14)
        let size = CGSize(width: back + length + w * 0.6, height: w * 2)
        let image = Paint.image(size: size, scale: scale) { _ in
            let y = size.height / 2
            // The counterweight behind the pivot.
            NSGradient(colors: [NSColor(white: 0.75, alpha: 1), NSColor(white: 0.3, alpha: 1)])?
                .draw(in: NSBezierPath(roundedRect: NSRect(x: 0, y: y - w * 0.42, width: back * 0.55, height: w * 0.84), xRadius: 3, yRadius: 3), angle: -90)
            // The arm: a thin silver tube.
            let tube = NSBezierPath()
            tube.move(to: CGPoint(x: back * 0.5, y: y)); tube.line(to: CGPoint(x: back + length * 0.9, y: y))
            tube.lineWidth = max(w * 0.18, 2.5)
            tube.lineCapStyle = .round
            NSColor(white: 0, alpha: 0.35).setStroke(); tube.stroke()
            tube.lineWidth = max(w * 0.13, 2)
            NSColor(white: 0.86, alpha: 1).setStroke(); tube.stroke()
            // The pivot.
            NSGradient(colors: [NSColor(white: 0.85, alpha: 1), NSColor(white: 0.35, alpha: 1)])?
                .draw(in: NSBezierPath(ovalIn: NSRect(x: back - w * 0.5, y: y - w * 0.5, width: w, height: w)), angle: -60)
            NSColor(white: 0.15, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: back - w * 0.15, y: y - w * 0.15, width: w * 0.3, height: w * 0.3)).fill()
            // The headshell, at the stylus end.
            let head = NSRect(x: back + length * 0.86, y: y - w * 0.3, width: length * 0.14 + w * 0.3, height: w * 0.6)
            NSGradient(colors: [NSColor(white: 0.25, alpha: 1), NSColor(white: 0.08, alpha: 1)])?
                .draw(in: NSBezierPath(roundedRect: head, xRadius: 2, yRadius: 2), angle: -90)
            NSColor(white: 1, alpha: 0.25).setStroke()
            NSBezierPath(roundedRect: head, xRadius: 2, yRadius: 2).stroke()
        }
        return (image, back, size)
    }

    private static func vinylImage(side: CGFloat, scale: CGFloat) -> CGImage? {
        Paint.image(size: CGSize(width: side, height: side), scale: scale) { ctx in
            let r = side / 2, c = CGPoint(x: r, y: r)
            let vinyl = r * Record.vinyl
            NSColor(white: 0.04, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - vinyl, y: c.y - vinyl, width: vinyl * 2, height: vinyl * 2)).fill()
            var rng = SeededRandom(seed: 33)
            // Grooves: fine rings of slightly different shades, with a smooth band between songs.
            for rad in stride(from: r * Record.label / 2 * 1.05, to: vinyl * 0.985, by: 1.1) {
                let band = (rad / vinyl - 0.36) / 0.6
                let gap = [0.22, 0.47, 0.71].contains { abs(band - $0) < 0.012 }
                NSColor(white: gap ? 0.1 : .random(in: 0.06...0.14, using: &rng), alpha: 1).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                ring.lineWidth = 0.6
                ring.stroke()
            }
            NSColor(white: 1, alpha: 0.12).setStroke() // the edge
            NSBezierPath(ovalIn: NSRect(x: c.x - vinyl + 0.5, y: c.y - vinyl + 0.5, width: vinyl * 2 - 1, height: vinyl * 2 - 1)).stroke()
            _ = ctx
        }
    }

    private static func platterImage(side: CGFloat, scale: CGFloat, metal: SkinColor) -> CGImage? {
        Paint.image(size: CGSize(width: side, height: side), scale: scale) { _ in
            let r = side / 2, c = CGPoint(x: r, y: r)
            let rim = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1))
            NSGradient(colors: [metal.mixed(SkinColor(1, 1, 1), 0.35).ns, metal.mixed(SkinColor(0, 0, 0), 0.4).ns])?.draw(in: rim, angle: -70)
            // Strobe dots round the rim (for setting the speed, on the real thing).
            NSColor(white: 0, alpha: 0.45).setFill()
            for i in 0..<120 {
                let a = CGFloat(i) / 120 * 2 * .pi
                let p = CGPoint(x: c.x + cos(a) * r * 0.978, y: c.y + sin(a) * r * 0.978)
                NSRect(x: p.x - 0.9, y: p.y - 0.9, width: 1.8, height: 1.8).fill()
            }
        }
    }

    private func showPrint(on disc: CALayer) {
        disc.contents = print ?? cover
        disc.contentsGravity = print != nil ? .resize : .resizeAspectFill // the print is already disc-shaped
    }

    /// Wraps the cover around a disc of `side` points on a background queue, then hands it over.
    private func renderPrint(side: CGFloat, then apply: @escaping @MainActor (CGImage?) -> Void) {
        printJob += 1
        let job = printJob
        guard let cover else { apply(nil); return }
        let pixels = Int((side * (window?.backingScaleFactor ?? 2)).rounded())
        let inner = Double(CD.print)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = DiscPrint.make(from: cover, side: pixels, inner: inner)
            DispatchQueue.main.async {
                onMainActor { [weak self] in
                    guard let self, self.printJob == job else { return }
                    apply(image)
                }
            }
        }
    }

    /// A ring (outer circle minus inner circle), wound so it works as a fill, a mask or a shadow.
    private static func ring(_ c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: c, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        p.closeSubpath()
        p.move(to: CGPoint(x: c.x + inner, y: c.y))
        p.addArc(center: c, radius: inner, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
        p.closeSubpath()
        return p
    }

    private static func shape(_ path: CGPath, in bounds: CGRect) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = bounds
        l.path = path
        return l
    }

    /// Around the disc: faint rainbow everywhere, two bright white-rainbow streaks opposite
    /// each other (light reflecting off the tracks), fading softly between. On a record, the
    /// same light without the rainbow.
    private static func lusterColors(rainbow: Bool) -> [CGColor] {
        (0...24).map { i -> CGColor in
            let angle = Double(i) / 24 * 360
            func streak(_ center: Double) -> Double {
                let d = abs((angle - center + 540).truncatingRemainder(dividingBy: 360) - 180)
                return exp(-d * d / (2 * 16 * 16))
            }
            let glint = max(streak(35), streak(215))
            guard rainbow else { return NSColor(white: 1, alpha: 0.02 + 0.16 * glint).cgColor }
            return NSColor(hue: (angle / 180).truncatingRemainder(dividingBy: 1), saturation: 0.55 - 0.3 * glint,
                           brightness: 1, alpha: 0.1 + 0.4 * glint).cgColor
        }
    }

    private func addSpin(to layer: CALayer) {
        layer.removeAnimation(forKey: "spin")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.byValue = -2 * Double.pi // clockwise, like a record
        // A record turns at its own steady pace (33⅓ would blur); a cassette's hubs turn quickly.
        spin.duration = switch media {
        case .cd: lively ? 14 : 30
        case .record: lively ? 9 : 20
        case .cassette: lively ? 3 : 6
        }
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        layer.add(spin, forKey: "spin")
    }

    // MARK: Following the song (the tonearm, the tape)

    /// Moves the tonearm and the tape to where the song is, then lets them travel on with it
    /// to its end. Only re-aimed when the song, play state or position really changes.
    private func followSong(force: Bool) {
        guard media != .cd else { tonearm.isHidden = true; return }
        let now = CACurrentMediaTime()
        guard let song else {
            followed = nil
            aimTonearm(from: Record.rest, to: nil, duration: 0)
            return
        }
        let position = song.playing ? song.position + (now - song.measuredAt) : song.position
        // (The length too: some players only know it a moment after the song starts.)
        if !force, let f = followed, f.title == song.title, f.duration == song.duration, f.playing == song.playing {
            let expected = f.playing ? f.position + (now - f.at) : f.position
            if abs(expected - position) < 1.5 { return }
        }
        followed = (song.title, song.duration, song.playing, position, now)
        let fraction = song.duration > 0 ? position / song.duration : 0
        let remaining = song.duration > 0 ? max(song.duration - position, 0) : 0
        let moving = song.playing && running && remaining > 0
        switch media {
        case .record:
            aimTonearm(from: Self.tonearmAngle(fraction: fraction), to: moving ? Self.tonearmAngle(fraction: 1) : nil, duration: remaining)
        case .cassette:
            for (i, pack) in packs.enumerated() {
                let amount = { (f: Double) in i == 0 ? 1 - f : f }
                let scale = { (f: Double) in NowPlayingSides.tapeRadius(amount(f), hub: self.packHub, full: 1) }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                pack.removeAnimation(forKey: "wind")
                pack.transform = CATransform3DMakeScale(scale(fraction), scale(fraction), 1)
                CATransaction.commit()
                guard moving else { continue }
                let wind = CABasicAnimation(keyPath: "transform.scale")
                wind.fromValue = scale(fraction)
                wind.toValue = scale(1)
                wind.duration = remaining
                wind.fillMode = .forwards
                wind.isRemovedOnCompletion = false
                wind.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
                pack.add(wind, forKey: "wind")
            }
        case .cd:
            break
        }
    }

    private func aimTonearm(from start: CGFloat, to end: CGFloat?, duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tonearm.removeAnimation(forKey: "travel")
        tonearm.removeAnimation(forKey: "leave")
        tonearm.opacity = 1
        let was = (tonearm.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? start
        tonearm.transform = CATransform3DMakeRotation(start, 0, 0, 1)
        CATransaction.commit()
        // A new song or a seek: the arm swings over first, then travels on with the song.
        let swing = abs(was - start) > 0.01 && running ? 0.8 : 0
        if swing > 0 {
            let move = CABasicAnimation(keyPath: "transform.rotation.z")
            move.fromValue = was
            move.toValue = start
            move.duration = swing
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tonearm.add(move, forKey: "swing")
        }
        if let end, duration > swing {
            let travel = CABasicAnimation(keyPath: "transform.rotation.z")
            travel.fromValue = start
            travel.toValue = end
            // Not filled backwards: until it begins, the swing shows.
            travel.beginTime = swing > 0 ? tonearm.convertTime(CACurrentMediaTime(), from: nil) + swing : 0
            travel.duration = duration - swing
            travel.fillMode = .forwards
            travel.isRemovedOnCompletion = false
            travel.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
            tonearm.add(travel, forKey: "travel")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutScene(force: false)
    }

    private var laidOut = CGSize.zero

    private func layoutScene(force: Bool) {
        guard force || bounds.size != laidOut, bounds.width > 0 else { return }
        laidOut = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        discStage.frame = bounds
        let area = CGRect(x: 0, y: bottomInset, width: bounds.width, height: bounds.height - topInset - bottomInset)
        let side = min(area.height * 0.66, area.width * 0.46)
        discRect = CGRect(x: area.midX - side / 2, y: area.midY - side / 2 + area.height * 0.03, width: side, height: side).integral
        mediaRect = media == .cassette
            ? CGRect(x: discRect.minX + Tape.tapeRect.minX * side, y: discRect.minY + Tape.tapeRect.minY * side,
                     width: Tape.tapeRect.width * side, height: Tape.tapeRect.height * side)
            : discRect
        ambient.arrange(in: bounds, around: discRect)
        ambient.animated = lively
        sides.lively = lively
        sides.place(around: discRect)
        let fresh = makeMedia()
        discStage.replaceSublayer(holder, with: fresh)
        holder = fresh
        spinners.forEach(addSpin)
        if media == .cd {
            renderPrint(side: side) { [weak self] image in // this size's print
                guard let self, self.media == .cd, let disc = self.spinners.first else { return }
                self.print = image
                self.showPrint(on: disc)
            }
        }
        // The light on the disc: rainbow on a CD, plain on a record, none on a cassette.
        sheen.isHidden = media == .cassette
        sheen.colors = Self.lusterColors(rainbow: media == .cd)
        sheen.frame = discRect
        // Shine over the middle of the disc only: none in the hole, full around the hub,
        // fading out softly before the edge. (A record's grooves shine all the way out.)
        let lusterMask = CAGradientLayer()
        lusterMask.type = .radial
        lusterMask.frame = CGRect(x: 0, y: 0, width: side, height: side)
        lusterMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        lusterMask.endPoint = CGPoint(x: 1, y: 1)
        lusterMask.colors = [NSColor.clear, .clear, .white, .white, .clear].map(\.cgColor)
        let stops: [CGFloat] = media == .record
            ? [0, Record.label / 2, Record.label / 2 + 0.01, Record.vinyl * 0.5 * 0.9, Record.vinyl * 0.5]
            : [0, CD.hole, CD.hole + 0.01, CD.luster * 0.65, CD.luster]
        lusterMask.locations = stops.map { NSNumber(value: Double($0)) }
        sheen.mask = lusterMask
        sheen.removeAnimation(forKey: "sway")
        if lively {
            // The light shifts a little, now and then: the streaks drift slowly back and forth.
            let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            sway.values = [0, 0.16, -0.08, 0.1, 0]
            sway.duration = 16
            sway.calculationMode = .cubic
            sway.repeatCount = .infinity
            sway.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            sheen.add(sway, forKey: "sway")
        }

        // The tonearm, pivoting in the square's top-right corner, over the record.
        tonearm.isHidden = media != .record
        if media == .record {
            let r = side / 2
            let (image, back, size) = Self.tonearmImage(length: Record.arm * r, scale: window?.backingScaleFactor ?? 2)
            tonearm.transform = CATransform3DIdentity
            tonearm.bounds = CGRect(origin: .zero, size: size)
            tonearm.anchorPoint = CGPoint(x: back / size.width, y: 0.5)
            tonearm.position = CGPoint(x: discRect.midX + Record.pivot.x * r, y: discRect.midY + Record.pivot.y * r)
            tonearm.contents = image
            tonearm.contentsScale = window?.backingScaleFactor ?? 2
            tonearm.shadowColor = NSColor.black.cgColor
            tonearm.shadowOpacity = 0.5
            tonearm.shadowRadius = 6
            tonearm.shadowOffset = CGSize(width: 2, height: -6)
        }
        followSong(force: true)

        runners.sublayers?.forEach { $0.removeFromSuperlayer() }
        runners.frame = bounds
        if lively { addRunners(groundY: bottomInset + 18) }
        CATransaction.commit()
        updateClock()
    }

    // MARK: Runners

    private func addRunners(groundY: CGFloat) {
        let animals = ["🐕", "🐈", "🐇", "🐿️", "🦔", "🐁", "🐧", "🐥", "🐖", "🐢"].shuffled().prefix(5)
        var cast: [(image: CGImage, facesLeft: Bool, size: CGFloat, speed: CGFloat)] = animals.compactMap { emoji in
            Sprites.emoji(emoji, size: 64).map { ($0, true, CGFloat.random(in: 46...62), emoji == "🐢" ? 0.45 : 1) }
        }
        if let girl = Sprites.chibi(hair: NSColor(red: 0.98, green: 0.62, blue: 0.78, alpha: 1),
                                    outfit: NSColor(red: 0.42, green: 0.55, blue: 0.95, alpha: 1), catEars: true) {
            cast.append((girl, false, 78, 0.8))
        }
        if let boy = Sprites.chibi(hair: NSColor(red: 0.30, green: 0.26, blue: 0.45, alpha: 1),
                                   outfit: NSColor(red: 0.98, green: 0.78, blue: 0.35, alpha: 1), catEars: false) {
            cast.append((boy, false, 74, 0.9))
        }
        let now = CACurrentMediaTime()
        for (i, actor) in cast.shuffled().enumerated() {
            let rightward = i % 2 == 0
            let runner = CALayer()       // crosses the screen
            let hopper = CALayer()       // hops and waddles
            let sprite = CALayer()       // the picture, mirrored to face the way it runs
            let size = CGSize(width: actor.size, height: actor.size * CGFloat(actor.image.height) / CGFloat(actor.image.width))
            for l in [runner, hopper, sprite] { l.bounds = CGRect(origin: .zero, size: size) }
            hopper.position = CGPoint(x: size.width / 2, y: size.height / 2)
            sprite.position = hopper.position
            sprite.contents = actor.image
            sprite.contentsGravity = .resizeAspect
            sprite.contentsScale = 2
            if actor.facesLeft == rightward { sprite.transform = CATransform3DMakeScale(-1, 1, 1) }
            hopper.addSublayer(sprite)
            runner.addSublayer(hopper)
            runner.opacity = 0.92
            let lane = groundY + CGFloat(i % 3) * 10 + size.height / 2
            let start = rightward ? -size.width : bounds.width + size.width
            let end = rightward ? bounds.width + size.width : -size.width
            runner.position = CGPoint(x: start, y: lane) // off screen until its first run
            runners.addSublayer(runner)

            let cross = CABasicAnimation(keyPath: "position.x")
            cross.fromValue = start
            cross.toValue = end
            // Each one takes its own time across and rests off screen a while: never a parade.
            let across = Double(bounds.width / (110 * actor.speed))
            cross.duration = across
            let loop = CAAnimationGroup()
            loop.animations = [cross]
            loop.duration = across + Double.random(in: 6...22)
            loop.repeatCount = .infinity
            loop.beginTime = now + Double(i) * 5.5 + Double.random(in: 0...3)
            loop.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            runner.add(loop, forKey: "run")

            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, actor.speed < 0.6 ? 3 : 11, 0]
            hop.keyTimes = [0, 0.45, 1]
            hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            hop.duration = actor.speed < 0.6 ? 0.9 : Double.random(in: 0.34...0.48)
            let waddle = CABasicAnimation(keyPath: "transform.rotation.z")
            waddle.fromValue = -0.07
            waddle.toValue = 0.07
            waddle.autoreverses = true
            waddle.duration = hop.duration
            waddle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for a in [hop, waddle] as [CAAnimation] {
                a.repeatCount = .infinity
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
                hopper.add(a, forKey: nil)
            }
        }
    }

    // MARK: Pausing

    /// Freezes / resumes every animation in the scene where it is.
    private func updateClock() {
        for layer in [stage, discStage] {
            if running, layer.speed == 0 {
                let paused = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
            } else if !running, layer.speed != 0 {
                let now = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = now
            }
        }
    }
}

/// The scene's characters, drawn once.
@MainActor
enum Sprites {
    private static var cache: [String: CGImage] = [:]

    static func emoji(_ text: String, size: CGFloat) -> CGImage? {
        if let hit = cache[text] { return hit }
        let font = NSFont(name: "Apple Color Emoji", size: size) ?? .systemFont(ofSize: size)
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let box = string.size()
        let image = NSImage(size: NSSize(width: ceil(box.width), height: ceil(box.height)), flipped: false) { _ in
            string.draw(at: .zero)
            return true
        }
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cache[text] = cg
        return cg
    }

    /// An original chibi character: big head, big shiny eyes, blush, tiny body.
    static func chibi(hair: NSColor, outfit: NSColor, catEars: Bool) -> CGImage? {
        let key = "chibi \(hair) \(outfit) \(catEars)"
        if let hit = cache[key] { return hit }
        let skin = NSColor(red: 1, green: 0.9, blue: 0.82, alpha: 1)
        let image = NSImage(size: NSSize(width: 80, height: 104), flipped: false) { _ in
            func oval(_ r: NSRect, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn: r).fill() }
            // legs and shoes
            NSColor(white: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: 2, width: 9, height: 14), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: 43, y: 2, width: 9, height: 14), xRadius: 4, yRadius: 4).fill()
            // body: a little A-line outfit
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 26, y: 14)); body.line(to: NSPoint(x: 54, y: 14))
            body.line(to: NSPoint(x: 49, y: 42)); body.line(to: NSPoint(x: 31, y: 42)); body.close()
            outfit.setFill(); body.fill()
            oval(NSRect(x: 21, y: 26, width: 9, height: 9), skin)  // hands
            oval(NSRect(x: 50, y: 26, width: 9, height: 9), skin)
            // hair behind, ears, face
            oval(NSRect(x: 6, y: 34, width: 68, height: 66), hair)
            if catEars {
                for (x, dir) in [(14.0, 1.0), (66.0, -1.0)] {
                    let ear = NSBezierPath()
                    ear.move(to: NSPoint(x: x, y: 82)); ear.line(to: NSPoint(x: x + dir * 4, y: 102))
                    ear.line(to: NSPoint(x: x + dir * 18, y: 90)); ear.close()
                    hair.setFill(); ear.fill()
                }
            }
            oval(NSRect(x: 13, y: 36, width: 54, height: 50), skin)
            // bangs
            hair.setFill()
            let bangs = NSBezierPath()
            bangs.move(to: NSPoint(x: 10, y: 74))
            for (i, x) in stride(from: 10.0, through: 70, by: 12).enumerated() {
                bangs.line(to: NSPoint(x: x + 6, y: i % 2 == 0 ? 68 : 72))
                bangs.line(to: NSPoint(x: x + 12, y: 78))
            }
            bangs.line(to: NSPoint(x: 72, y: 96)); bangs.line(to: NSPoint(x: 8, y: 96)); bangs.close()
            bangs.fill()
            // eyes: dark ovals with a colored lower half and two highlights
            for x in [24.0, 45.0] {
                oval(NSRect(x: x, y: 50, width: 11, height: 15), NSColor(red: 0.18, green: 0.12, blue: 0.2, alpha: 1))
                oval(NSRect(x: x + 1.5, y: 50.5, width: 8, height: 7), hair.blended(withFraction: 0.35, of: .white) ?? hair)
                oval(NSRect(x: x + 1.5, y: 58, width: 4.5, height: 4.5), .white)
                oval(NSRect(x: x + 6.5, y: 53, width: 2, height: 2), .white)
            }
            oval(NSRect(x: 16, y: 44, width: 10, height: 5), NSColor(red: 1, green: 0.5, blue: 0.6, alpha: 0.5)) // blush
            oval(NSRect(x: 54, y: 44, width: 10, height: 5), NSColor(red: 1, green: 0.5, blue: 0.6, alpha: 0.5))
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 36, y: 45)); mouth.curve(to: NSPoint(x: 44, y: 45),
                                                           controlPoint1: NSPoint(x: 38, y: 41), controlPoint2: NSPoint(x: 42, y: 41))
            mouth.lineWidth = 1.6
            NSColor(red: 0.55, green: 0.25, blue: 0.3, alpha: 1).setStroke(); mouth.stroke()
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache[key] = cg
        return cg
    }
}

/// Which way discs move when the song changes.
enum DiscDirection {
    case forward   // next song: old disc out to the left, new one in from the right
    case backward  // previous song: the other way round
}
