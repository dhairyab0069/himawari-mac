import AppKit
import AVFoundation
import HimawariKit

/// Makes the side gear and the CD playable, while the rest of the desktop stays click-through.
///
/// The wallpaper sits below Finder's icons, so it never gets clicks. Instead, one small
/// invisible window sits over each control, just above the icons (like the desktop clock):
/// the transport buttons, REPEAT and SHUFFLE, the progress ladder, the jog wheel, the VOLUME,
/// BASS and TREBLE knobs, and the disc.
/// Each turns clicks and drags into what the control does, and shows it on the gear.
@MainActor
final class GearControls {
    enum Action {
        case button(GearControl)            // previous, play/pause, next, stop, eject, repeat, shuffle
        case seek(fraction: Double)          // a click on the progress ladder
        case scrub(seconds: Double)          // the jog wheel or the disc, let go: jump this far
        case volume(Double, done: Bool)      // the VOLUME knob, 0…1
        case tone(bass: Double, treble: Double, done: Bool) // the BASS and TREBLE knobs, dB
    }

    /// What to do with each action (Music commands, in AppDelegate).
    var perform: ((Action) -> Void)?
    /// The song's length and where it is now (for the ladder and scrubbing limits).
    var song: () -> (position: Double, duration: Double)? = { nil }
    /// Music's volume (0…1), read when you grab the knob.
    var volumeNow: (@escaping (Double) -> Void) -> Void = { $0(0.5) }

    private var catchers: [Catcher] = []
    private let scratch = ScratchSound()

    /// Puts a catcher over every control that's on screen now; removes the rest.
    func update(gear: [NowPlayingSides], scenes: [MusicScene], active: Bool) {
        var wanted: [(key: String, rect: NSRect, make: () -> Catcher)] = []
        if active {
            for view in gear where view.window != nil {
                for (control, rect) in view.controlRects {
                    guard let screen = Self.screenRect(rect, in: view) else { continue }
                    wanted.append(("\(view.catcherKey).\(control)", screen, { [unowned self] in
                        self.catcher(for: control, gear: view)
                    }))
                }
            }
            for scene in scenes where scene.window != nil && scene.discRect.width > 0 {
                guard let screen = Self.screenRect(scene.discRect, in: scene) else { continue }
                wanted.append(("\(scene.catcherKey).disc", screen, { [unowned self] in self.discCatcher(scene) }))
            }
        }
        // Keep the ones still needed (just moved), close the others, add the new ones.
        var kept: [Catcher] = []
        for c in catchers {
            if let w = wanted.first(where: { $0.key == c.key }) {
                c.setFrame(w.rect, display: false)
                kept.append(c)
            } else {
                c.orderOut(nil)
            }
        }
        for w in wanted where !kept.contains(where: { $0.key == w.key }) {
            let c = w.make()
            c.key = w.key
            c.setFrame(w.rect, display: false)
            c.orderFrontRegardless()
            kept.append(c)
        }
        catchers = kept
    }

    private static func screenRect(_ rect: CGRect, in view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    // MARK: The controls

    private func catcher(for control: GearControl, gear: NowPlayingSides) -> Catcher {
        let c = Catcher()
        switch control {
        case .previous, .playPause, .next, .stop, .eject, .repeatMode, .shuffle:
            c.onDown = { [weak self, weak gear] _ in
                gear?.press(control)
                self?.perform?(.button(control))
            }
        case .progress:
            c.onDown = { [weak self, weak gear] point in
                guard let gear, let width = gear.controlRects[.progress]?.width, width > 0 else { return }
                gear.press(.progress)
                self?.perform?(.seek(fraction: min(max(point.x / width, 0), 1)))
            }
        case .jog:
            // Clockwise is forward; one full turn of the wheel is 10 seconds.
            var turn = Turn()
            c.onDown = { [weak self, unowned c] point in turn.begin(at: point, in: c.contentView?.bounds ?? .zero); self?.scratch.start() }
            c.onDrag = { [weak self, weak gear] point in
                let step = turn.move(to: point)
                gear?.scrub(by: self?.clamped(-turn.total / (2 * .pi) * 10) ?? 0, angle: turn.total)
                self?.scratch.speed = abs(step) * 60
            }
            c.onUp = { [weak self, weak gear] _ in
                let seconds = self?.clamped(-turn.total / (2 * .pi) * 10) ?? 0
                gear?.endScrub()
                self?.scratch.stop()
                if abs(seconds) > 0.2 { self?.perform?(.scrub(seconds: seconds)) }
            }
        case .volume:
            // Drag up for louder, down for quieter; 150 points from silent to full.
            var start: CGFloat = 0, level = 0.5, dragged = false
            c.onDown = { [weak self, weak gear] point in
                start = point.y
                dragged = false
                level = gear?.volume ?? 0.5 // what the knob shows now; Music's exact value follows
                self?.volumeNow { now in
                    guard !dragged else { return } // don't make the knob jump under your finger
                    level = now; gear?.volume = now
                }
            }
            c.onDrag = { [weak self, weak gear] point in
                dragged = true
                let v = min(max(level + Double(point.y - start) / 150, 0), 1)
                gear?.volume = v
                self?.perform?(.volume(v, done: false))
            }
            c.onUp = { [weak self, weak gear] point in
                guard dragged else { return } // a click without a drag changes nothing
                let v = min(max(level + Double(point.y - start) / 150, 0), 1)
                gear?.volume = v
                self?.perform?(.volume(v, done: true))
            }
        case .bass, .treble:
            // Like VOLUME: drag up to boost, down to cut; 150 points across ±12 dB. Double-click: flat.
            var start: CGFloat = 0, level = 0.5, dragged = false
            let send = { [weak self, weak gear] (v: Double, done: Bool) in
                guard let gear else { return }
                let dB = ((v * 24 - 12) * 2).rounded() / 2 // half-dB steps
                if control == .bass { gear.bass = dB } else { gear.treble = dB }
                self?.perform?(.tone(bass: gear.bass, treble: gear.treble, done: done))
            }
            c.onDown = { [weak gear] point in
                start = point.y
                dragged = false
                level = gear?.knobValue(control) ?? 0.5
            }
            c.onDrag = { point in
                dragged = true
                send(min(max(level + Double(point.y - start) / 150, 0), 1), false)
            }
            // Only a drag sets the tone: a plain click (or the clicks of a double-click) must not
            // switch Music's equalizer on, or resend the old value after "flat".
            c.onUp = { point in if dragged { send(min(max(level + Double(point.y - start) / 150, 0), 1), true) } }
            c.onDoubleClick = { [weak gear] in
                gear?.press(control)
                send(0.5, true)
            }
        }
        return c
    }

    /// The CD: grab it and turn it like a record to scrub (a full turn is 8 seconds), with sound.
    private func discCatcher(_ scene: MusicScene) -> Catcher {
        let c = Catcher()
        c.round = true
        var turn = Turn()
        c.onDown = { [weak self, weak scene, unowned c] point in
            turn.begin(at: point, in: c.contentView?.bounds ?? .zero)
            scene?.grabDisc()
            self?.scratch.start()
        }
        c.onDrag = { [weak self, weak scene] point in
            let step = turn.move(to: point)
            scene?.turnDisc(by: turn.total)
            scene?.gear?.scrub(by: self?.clamped(-turn.total / (2 * .pi) * 8) ?? 0, angle: 0)
            self?.scratch.speed = abs(step) * 60
        }
        c.onUp = { [weak self, weak scene] _ in
            let seconds = self?.clamped(-turn.total / (2 * .pi) * 8) ?? 0
            scene?.releaseDisc()
            scene?.gear?.endScrub()
            self?.scratch.stop()
            if abs(seconds) > 0.2 { self?.perform?(.scrub(seconds: seconds)) }
        }
        return c
    }

    /// Keeps a scrub inside the song.
    private func clamped(_ seconds: Double) -> Double {
        guard let s = song() else { return seconds }
        return min(max(seconds, -s.position), max(s.duration - s.position - 1, 0))
    }

    /// Following a drag around a center: how far it has turned, in radians (counterclockwise).
    private struct Turn {
        var center = CGPoint.zero, last: CGFloat = 0
        private(set) var total: CGFloat = 0

        mutating func begin(at point: CGPoint, in bounds: CGRect) {
            center = CGPoint(x: bounds.midX, y: bounds.midY)
            last = atan2(point.y - center.y, point.x - center.x)
            total = 0
        }

        /// Returns this step's turn.
        mutating func move(to point: CGPoint) -> CGFloat {
            let angle = atan2(point.y - center.y, point.x - center.x)
            var step = angle - last
            if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi } // across ±180°
            last = angle
            total += step
            return step
        }
    }
}

/// An invisible window over one control, above Finder's icons. It catches clicks only where
/// the control is: everything around it stays the desktop.
@MainActor
private final class Catcher: NSPanel {
    var key = ""
    var round = false { didSet { (contentView as? CatcherView)?.round = round } }
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = DesktopLayer.level(DesktopLayer.folders)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let view = CatcherView()
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}

@MainActor
private final class CatcherView: NSView {
    weak var owner: Catcher?
    var round = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Not quite transparent: macOS passes clicks through fully clear pixels.
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.004).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = round ? bounds.width / 2 : 6
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard round else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        let r = bounds.width / 2
        return hypot(p.x - bounds.midX, p.y - bounds.midY) <= r ? self : nil // the disc is round
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let double = owner?.onDoubleClick { return double() }
        owner?.onDown?(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { owner?.onDrag?(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { owner?.onUp?(convert(event.locationInWindow, from: nil)) }
}

/// The sound of a disc being turned by hand: soft filtered noise and a low whirr that rise and
/// fall with how fast it turns. Made on the fly, no sound files; quiet, and silent at rest.
@MainActor
final class ScratchSound {
    /// How fast the disc is turning (roughly 0…10).
    var speed: Double = 0 { didSet { state.speed = speed } }
    private var engine: AVAudioEngine?
    private let state = ScratchState()
    private var stopWork: DispatchWorkItem?

    func start() {
        stopWork?.cancel()
        if engine == nil {
            let engine = AVAudioEngine()
            let format = engine.outputNode.inputFormat(forBus: 0)
            let rate = format.sampleRate > 0 ? format.sampleRate : 48000
            let state = self.state
            let source = AVAudioSourceNode { _, _, frames, buffers -> OSStatus in
                state.render(frames: Int(frames), rate: rate, into: UnsafeMutableAudioBufferListPointer(buffers))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            engine.mainMixerNode.outputVolume = 0.6
            do { try engine.start() } catch { Log.write("scratch sound: \(error.localizedDescription)"); return }
            self.engine = engine
        }
        speed = 0
    }

    /// The sound fades out, then the audio engine shuts down (nothing runs while idle).
    func stop() {
        speed = 0
        let work = DispatchWorkItem { [weak self] in
            onMainActor {
                self?.engine?.stop()
                self?.engine = nil
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

/// The sound generator's state, touched by the audio thread (speed is set from the main thread;
/// a torn read of a Double here only makes one buffer a little louder or quieter).
private final class ScratchState: @unchecked Sendable {
    var speed: Double = 0
    private var level: Double = 0, lowpass: Double = 0, phase: Double = 0
    private var seed: UInt32 = 0x9E3779B9

    func render(frames: Int, rate: Double, into buffers: UnsafeMutableAudioBufferListPointer) {
        let target = min(speed / 10, 1)
        for i in 0..<frames {
            level += (target - level) * 0.0015                  // smooth fades, no clicks
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let cutoff = 0.02 + 0.25 * level                     // faster turns sound brighter
            lowpass += (noise - lowpass) * cutoff
            phase += 2 * .pi * (50 + 300 * level) / rate          // the whirr rises with speed
            if phase > 2 * .pi { phase -= 2 * .pi }
            let sample = Float((lowpass * 0.6 + sin(phase) * 0.15) * level * 0.35)
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[i] = sample
            }
        }
    }
}
