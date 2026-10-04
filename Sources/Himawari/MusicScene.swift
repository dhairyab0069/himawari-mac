import AppKit
import HimawariKit
import QuartzCore

/// For songs with no motion artwork (and no YouTube video): the album cover as a CD
/// slowly spinning over a soft glow in the cover's colors, with little animals and
/// chibi characters running along the bottom. All Core Animation, drawn by the window
/// server at a low frame rate; everything stops when the music (or the wallpaper) pauses.
@MainActor
final class MusicScene: NSView {
    /// Names this view's click catchers. Not ObjectIdentifier: a view rebuilt after a screen change
    /// can reuse a freed one's address, and its catchers would keep pointing at the old view.
    let catcherKey = UUID().uuidString
    private let stage = CALayer()      // everything; its clock is what pausing stops
    private let discStage = CALayer() // the discs and their luster, above the side gear
    private let ambient = AmbientLayer()
    private var holder = CALayer()     // carries the disc and its shadow; slides when the CD changes
    private var disc = CALayer()       // the cover: the part that spins
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
    /// Where the CD is (this view's coordinates, y up).
    private(set) var discRect = CGRect.zero

    var running = true { didSet { if running != oldValue { updateClock() } } }
    private let sides = NowPlayingSides(frame: .zero)
    var meterSource: AudioLevels? { didSet { sides.meterSource = meterSource } }
    func levelsChanged() { sides.levelsChanged() }
    /// The side gear beside the disc (for the click catchers).
    var gear: NowPlayingSides? { sides.isHidden ? nil : sides }

    // MARK: Spinning the disc by hand

    private var grabbedAt: CGFloat = 0

    /// You grabbed the disc: it stops turning by itself, right where it was.
    func grabDisc() {
        grabbedAt = (disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.removeAnimation(forKey: "spin")
        disc.removeAnimation(forKey: "spinUp")
        disc.transform = CATransform3DMakeRotation(grabbedAt, 0, 0, 1)
        CATransaction.commit()
    }

    /// …and it follows your hand, `angle` radians (counterclockwise) from where you grabbed it.
    func turnDisc(by angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.transform = CATransform3DMakeRotation(grabbedAt + angle, 0, 0, 1)
        CATransaction.commit()
    }

    /// Let go: it spins on by itself from where you left it.
    func releaseDisc() {
        addSpin(to: disc)
    }
    func setSong(_ info: SongInfo?, animating: Bool) {
        sides.isHidden = info == nil
        sides.animating = animating
        if let info { sides.show(info) }
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
        sheen.colors = Self.lusterColors()
        discStage.addSublayer(sheen)
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
        guard discRect.width > 0 else { disc.contents = cover; return }
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
        renderPrint(side: discRect.width) { [weak self] image in
            self?.print = image
            self?.swapDisc(direction)
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
        let dim = CABasicAnimation(keyPath: "opacity") // the luster goes with the light on the disc
        dim.toValue = 0
        dim.duration = 0.3
        dim.fillMode = .forwards
        dim.isRemovedOnCompletion = false
        sheen.add(dim, forKey: "leave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { fade() }
    }

    /// The same song's cover, sharper: print it and put it on the disc that's there, no change of discs.
    func repaint(with artwork: NSImage) {
        cover = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
        palette = cover.flatMap { FrameSampler($0) }.map(AmbientPalette.from) ?? .neutral
        ambient.show(palette)
        guard discRect.width > 0 else { return }
        renderPrint(side: discRect.width) { [weak self] image in
            guard let self else { return }
            self.print = image
            self.showPrint(on: self.disc)
        }
    }

    private func swapDisc(_ direction: DiscDirection) {
        let oldHolder = holder
        let center = CGPoint(x: discRect.midX, y: discRect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let (newHolder, newDisc) = makeDisc(side: discRect.width)
        discStage.insertSublayer(newHolder, above: oldHolder)
        addSpin(to: newDisc)
        CATransaction.commit()
        holder = newHolder
        disc = newDisc

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
        newDisc.add(spinUp, forKey: "spinUp")

        // The luster belongs to the light, not the disc: dim it while the discs move.
        for l in [sheen] as [CALayer] {
            let dip = CAKeyframeAnimation(keyPath: "opacity")
            dip.values = [1, 0, 0, 1]
            dip.keyTimes = [0, 0.2, 0.7, 1]
            dip.duration = 1.2
            dip.preferredFrameRateRange = rate
            l.add(dip, forKey: "dip")
        }
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

    /// One CD: the picture printed on it (the part that spins), a single silver ring around
    /// the center, and a real hole you can see through. The ring looks the same at every
    /// angle, so only the picture needs to turn.
    private func makeDisc(side: CGFloat) -> (holder: CALayer, disc: CALayer) {
        let r = side / 2, c = CGPoint(x: r, y: r)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let holder = CALayer()
        holder.bounds = bounds
        holder.position = CGPoint(x: discRect.midX, y: discRect.midY)
        holder.shadowColor = NSColor.black.cgColor
        holder.shadowOpacity = 0.55
        holder.shadowRadius = 30
        holder.shadowOffset = CGSize(width: 0, height: -12)
        holder.shadowPath = Self.ring(c, outer: r, inner: r * CD.hole) // no shadow in the hole

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
    /// each other (light reflecting off the tracks), fading softly between.
    private static func lusterColors() -> [CGColor] {
        (0...24).map { i -> CGColor in
            let angle = Double(i) / 24 * 360
            func streak(_ center: Double) -> Double {
                let d = abs((angle - center + 540).truncatingRemainder(dividingBy: 360) - 180)
                return exp(-d * d / (2 * 16 * 16))
            }
            let glint = max(streak(35), streak(215))
            return NSColor(hue: (angle / 180).truncatingRemainder(dividingBy: 1), saturation: 0.55 - 0.3 * glint,
                           brightness: 1, alpha: 0.1 + 0.4 * glint).cgColor
        }
    }

    private func addSpin(to layer: CALayer) {
        layer.removeAnimation(forKey: "spin")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.byValue = -2 * Double.pi // clockwise, like a record
        spin.duration = lively ? 14 : 30
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        layer.add(spin, forKey: "spin")
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
        ambient.arrange(in: bounds, around: discRect)
        ambient.animated = lively
        sides.lively = lively
        sides.place(around: discRect)
        let fresh = makeDisc(side: side)
        discStage.replaceSublayer(holder, with: fresh.holder)
        (holder, disc) = fresh
        addSpin(to: disc)
        renderPrint(side: side) { [weak self] image in // this size's print
            guard let self else { return }
            self.print = image
            self.showPrint(on: self.disc)
        }
        sheen.frame = discRect
        // Shine over the middle of the disc only: none in the hole, full around the hub,
        // fading out softly before the edge.
        let lusterMask = CAGradientLayer()
        lusterMask.type = .radial
        lusterMask.frame = CGRect(x: 0, y: 0, width: side, height: side)
        lusterMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        lusterMask.endPoint = CGPoint(x: 1, y: 1)
        lusterMask.colors = [NSColor.clear, .clear, .white, .white, .clear].map(\.cgColor)
        lusterMask.locations = [0, CD.hole, CD.hole + 0.01, CD.luster * 0.65, CD.luster].map { NSNumber(value: Double($0)) }
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
        cast.append((Sprites.chibi(hair: NSColor(red: 0.98, green: 0.62, blue: 0.78, alpha: 1),
                                   outfit: NSColor(red: 0.42, green: 0.55, blue: 0.95, alpha: 1), catEars: true), false, 78, 0.8))
        cast.append((Sprites.chibi(hair: NSColor(red: 0.30, green: 0.26, blue: 0.45, alpha: 1),
                                   outfit: NSColor(red: 0.98, green: 0.78, blue: 0.35, alpha: 1), catEars: false), false, 74, 0.9))
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
    static func chibi(hair: NSColor, outfit: NSColor, catEars: Bool) -> CGImage {
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
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        cache[key] = cg
        return cg
    }
}

/// Which way discs move when the song changes.
enum DiscDirection {
    case forward   // next song: old disc out to the left, new one in from the right
    case backward  // previous song: the other way round
}
