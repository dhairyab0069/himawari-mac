import AppKit
import HimawariKit
import SwiftUI

/// A big GNOME/KDE-style desktop clock: see-through glowing text, no panel.
/// Runs as its own background service (HimawariClock). Lives in a click-through
/// window above the video and below Finder's icons, inside the free area
/// (never under the widgets, the folders or the taskbar).
@MainActor
final class DesktopClock {
    private var window: DesktopWindow?
    private let tone = ClockTone()
    private let ticker = ClockTicker()
    private var reading: ToneReading?
    private var lastLogged: Double?

    init() {
        // Himawari's live measurements of what's on screen…
        WallpaperTone.observeReadings { [weak self] reading in
            guard let self else { return }
            self.reading = reading
            // Himawari doesn't know where we are yet (it started after us): tell it.
            if reading.focus == nil { self.tellHimawariWhereWeAre() }
            self.updateTone()
        }
        // The system time jumped (set by hand, time zone, network time) or the Mac woke up:
        // redraw now and restart the tick schedule from the real time.
        let resync: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { onMainActor { self?.placed = nil; self?.refresh() } }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: resync)
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: resync)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resync)
        // …or, until one arrives (or without Himawari), the regular macOS wallpaper.
        if let screen = NSScreen.main, let grid = WallpaperTone.systemWallpaperGrid(for: screen) {
            reading = ToneReading(grid: grid)
        }
    }

    private func tellHimawariWhereWeAre() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // Just the text, not the padding around it.
        WallpaperTone.requestReading(for: WallpaperTone.fraction(of: window.frame.insetBy(dx: 24, dy: 24), on: screen))
    }

    /// Bright behind the clock → dark text; dark → light text (with a little hysteresis so it doesn't flicker).
    private func updateTone() {
        guard let reading, let window, let screen = window.screen ?? NSScreen.main else { return }
        let b = reading.focus ?? WallpaperTone.brightness(of: reading.grid, under: window.frame, on: screen)
        let wasDark = tone.dark, wasBusy = tone.busy
        if tone.dark && b < 0.5 { tone.dark = false } else if !tone.dark && b > 0.6 { tone.dark = true }
        // A busy picture behind it (album art, a music video): stronger contrast.
        if let spread = reading.spread {
            if tone.busy && spread < 0.13 { tone.busy = false } else if !tone.busy && spread > 0.19 { tone.busy = true }
        }
        if tone.dark != wasDark || tone.busy != wasBusy || lastLogged == nil {
            print(String(format: "behind clock: brightness %.2f, busy %.2f → %@ text%@", b, reading.spread ?? 0,
                         tone.dark ? "dark" : "light", tone.busy ? ", extra contrast" : ""))
            fflush(stdout)
            lastLogged = b
        }
    }
    private var placed: String? // settings + position currently on screen

    /// Show, hide, or re-position the clock to match Settings. Called on every
    /// broadcast change; does nothing unless something about the clock changed.
    func refresh() {
        let s = Settings.shared
        let area = NSScreen.main.map { DesktopLayout.freeArea(of: $0) }
        let signature = [String(s.showClock), s.clockFormat.rawValue, String(s.clockSeconds), String(s.clockShowDate),
                         s.clockSize.rawValue, s.clockStyle.rawValue, s.clockPosition.rawValue,
                         area.map { NSStringFromRect($0) } ?? ""].joined(separator: "|")
        if signature == placed { return }
        placed = signature
        let wasAt = window?.frame
        window?.orderOut(nil)
        window = nil
        guard s.showClock, let screen = NSScreen.main else {
            ticker.stop()
            if let wasAt { showHiddenHint(at: wasAt) } // just hidden: say how to get it back
            return
        }
        let ticks = ClockFace.ticks(format: s.clockFormat, seconds: s.clockSeconds)
        ticker.run(anchor: ticks.anchor, step: ticks.step)

        // Above Finder's icons (like the folders), so the clock can be clicked.
        let w = DesktopWindow(layer: DesktopLayer.folders, interactive: true)
        w.host(ClockView(format: s.clockFormat, showSeconds: s.clockSeconds, showDate: s.clockShowDate,
                         size: s.clockSize, style: s.clockStyle, tone: tone, ticker: ticker))
        w.setFrameOrigin(Self.origin(for: s.clockPosition, size: w.frame.size, in: DesktopLayout.freeArea(of: screen),
                                     screenCenter: screen.visibleFrame.midX))
        w.orderFrontRegardless()
        window = w
        tellHimawariWhereWeAre()
        updateTone()
    }

    private var hint: DesktopWindow?

    /// A small note where the clock was, for a few seconds: how to bring it back.
    private func showHiddenHint(at frame: NSRect) {
        let w = DesktopWindow(layer: DesktopLayer.folders, interactive: false)
        w.host(ClockHiddenHint())
        w.setFrameOrigin(NSPoint(x: frame.midX - w.frame.width / 2, y: frame.midY - w.frame.height / 2))
        w.alphaValue = 0
        w.orderFrontRegardless()
        hint = w
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; w.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self, weak w] in
            guard let w else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; w.animator().alphaValue = 0 }) {
                onMainActor {
                    w.orderOut(nil)
                    if self?.hint === w { self?.hint = nil }
                }
            }
        }
    }

    /// Centered positions line up with the middle of the *screen* (not of the space left
    /// between the widgets and folders, which is lopsided); the clock only shifts over if
    /// a widget or folder column would otherwise be in the way.
    private static func origin(for position: ClockPosition, size: NSSize, in area: NSRect, screenCenter: CGFloat) -> NSPoint {
        let margin: CGFloat = 24
        var x: CGFloat
        switch position {
        case .topLeft, .bottomLeft: x = area.minX + margin
        case .topRight, .bottomRight: x = area.maxX - size.width - margin
        case .topCenter, .center:
            x = screenCenter - size.width / 2
            x = min(max(x, area.minX), area.maxX - size.width)
        }
        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight: y = area.maxY - size.height - margin
        case .center: y = area.midY - size.height / 2
        case .bottomLeft, .bottomRight: y = area.minY + margin
        }
        return NSPoint(x: x, y: y)
    }
}


/// "Clock hidden": shown for a few seconds where the clock was.
struct ClockHiddenHint: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Clock hidden").font(aeroFont(size: 17, weight: .semibold))
            Text("Bring it back with ⌃⌥⌘C, or the Himawari menu ▸ Show Desktop Clock")
                .font(aeroFont(size: 13))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }
}

/// Whether the clock should use dark text (over a bright wallpaper).
@MainActor
final class ClockTone: ObservableObject {
    @Published var dark = false
    @Published var busy = false
}

/// The clock. Left-click: the next way of telling the time. Right-click: its options.
struct ClockView: View {
    let format: ClockFormat
    let showSeconds: Bool
    let showDate: Bool
    let size: ClockSize
    let style: ClockStyle
    @ObservedObject var tone: ClockTone
    @ObservedObject var ticker: ClockTicker

    var body: some View {
        let face = ClockFace.parts(ticker.now, format: format, seconds: showSeconds)
        let big = (format == .words ? 58 : 110) * size.scale
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if format == .words {
                    Text(face.main).font(Font(nsFont(big, weight: .light)))
                } else {
                    // Every digit gets the same width, so nothing shifts as the seconds change.
                    FixedWidthDigits(text: face.main, font: nsFont(big, weight: .light))
                }
                if !face.small.isEmpty { Text(face.small).font(Font(nsFont(big * 0.33))) }
            }
            .modifier(ClockInk(dark: tone.dark, busy: tone.busy, vfd: style == .vfd, opacity: 0.8))
            if showDate {
                Text(face.caption ?? ticker.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Font(nsFont(26 * size.scale)))
                    .modifier(ClockInk(dark: tone.dark, busy: tone.busy, vfd: style == .vfd, opacity: 0.85))
            }
        }
        .animation(.easeInOut(duration: 0.8), value: tone.dark)
        .animation(.easeInOut(duration: 0.8), value: tone.busy)
        .padding(24) // room for the glow so it isn't clipped by the window
        .contentShape(Rectangle())
        .onTapGesture { change { $0.clockFormat = format.next } }
        .contextMenu { options }
    }

    private func nsFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        func designed(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        switch style {
        case .aero: return aeroNSFont(size: size, weight: weight)
        case .vfd: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .rounded: return designed(.rounded)
        case .serif: return designed(.serif)
        }
    }

    @ViewBuilder private var options: some View {
        Picker("Format", selection: binding(\.clockFormat)) {
            ForEach(ClockFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Toggle("Show Seconds", isOn: binding(\.clockSeconds))
        Toggle("Show Date", isOn: binding(\.clockShowDate))
        Divider()
        Picker("Size", selection: binding(\.clockSize)) {
            ForEach(ClockSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker("Style", selection: binding(\.clockStyle)) {
            ForEach(ClockStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker("Position", selection: binding(\.clockPosition)) {
            ForEach(ClockPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Button("Hide Clock (⌃⌥⌘C Shows It Again)") { change { $0.showClock = false } }
    }

/// A setting as a menu binding: changing it saves it and tells every process.
    private func binding<T>(_ key: ReferenceWritableKeyPath<HimawariKit.Settings, T>) -> Binding<T> {
        Binding(get: { HimawariKit.Settings.shared[keyPath: key] }, set: { value in change { $0[keyPath: key] = value } })
    }

    private func change(_ edit: (HimawariKit.Settings) -> Void) {
        edit(HimawariKit.Settings.shared)
        HimawariKit.Settings.broadcastChange()
    }
}

/// The clock's text: see-through white with an aqua glow on dark wallpapers;
/// deep navy with a white glow on bright ones, so it always stands out.
/// The fluorescent-display style glows cyan, with a dark halo so it reads on anything.
private struct ClockInk: ViewModifier {
    let dark: Bool
    let busy: Bool
    let vfd: Bool
    let opacity: Double

    func body(content: Content) -> some View {
        if vfd {
            content
                .foregroundStyle(Color(red: 0.45, green: 0.97, blue: 1).opacity(opacity + 0.1))
                .shadow(color: Color(red: 0.45, green: 0.97, blue: 1).opacity(0.8), radius: 8)
                .shadow(color: .black.opacity(dark || busy ? 0.8 : 0.45), radius: 3)
        } else if dark {
            content
                .foregroundStyle(Color(red: 0.05, green: 0.12, blue: 0.25).opacity(opacity))
                .shadow(color: .white.opacity(0.85), radius: 10)
                .shadow(color: .white.opacity(0.6), radius: 2)
                .shadow(color: .white.opacity(busy ? 0.9 : 0), radius: 18) // a soft light halo over busy art
        } else {
            content
                .foregroundStyle(.white.opacity(opacity))
                .shadow(color: .aeroGlow.opacity(0.6), radius: 10)
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1) // keeps white readable over busy areas
                .shadow(color: .black.opacity(busy ? 0.75 : 0), radius: 16) // a soft shade over busy art
        }
    }
}
