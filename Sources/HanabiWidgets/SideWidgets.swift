import AppKit
import Darwin
import HanabiKit
import IOKit.ps
import SwiftUI

/// A panel of Aero widgets on the desktop: calendar, battery, CPU & memory, storage.
///
/// It sits on the desktop layer, below app windows (like the folders), and
/// never takes focus from the app you're using.
/// It is DOCKED to a screen edge: a vertical column on the left/right, a
/// horizontal strip on the top/bottom. Drag it toward another edge and it
/// snaps there and re-orients. Its strip is reserved in DesktopLayout, so
/// app windows (WindowTiler), the folders and the clock all stay out of it.
/// Folding it into a tab gives the space back.
///
/// Runs as its own background service (Desktop Widgets), independent of the
/// wallpaper app.
@MainActor
final class SideWidgets {
    private var panel: WidgetPanel?
    private var placed: String? // what's on screen: settings + frame
    private let stats = SystemStats()
    private let music = MusicNowPlaying() // the Now Playing card (Apple Music)
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var placing = false          // true while WE move the panel (ignore those moves)
    private var snapWork: DispatchWorkItem?

    /// Force a full redraw (Battery Saver changed how the panel is drawn).
    func rebuild() {
        placed = nil
        stats.stop()
        refresh()
    }

    /// Called on every broadcast change; rebuilds only if the widgets' settings or
    /// the space they dock into changed (e.g. the taskbar appeared).
    func refresh() {
        let s = Settings.shared
        let area = NSScreen.main.map { DesktopLayout.freeArea(of: $0, excluding: [.widgets, .folders]) }
        let signature = "\(s.showWidgets)|\(s.widgetsCollapsed)|\(s.widgetEdge.rawValue)|\(area.map { NSStringFromRect($0) } ?? "")"
        if signature == placed { return }
        placed = signature

        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
        guard s.showWidgets, let screen = NSScreen.main, let area else {
            stats.stop()
            DesktopLayout.setZone(.widgets, nil)
            return
        }
        s.widgetsCollapsed ? stats.stop() : stats.start()
        music.youtubeFallback = s.youtubeLoops

        let edge = s.widgetEdge
        let p = WidgetPanel()
        let view = SideWidgetsView(stats: stats, music: music, collapsed: s.widgetsCollapsed, horizontal: !edge.isVertical) {
            Settings.shared.widgetsCollapsed.toggle()
            Settings.broadcastChange() // everyone re-tiles, including us
        }
        let hosting = FirstClickHostingView(rootView: view)
        p.contentView = hosting
        let size = hosting.fittingSize
        p.setContentSize(size)

        _ = screen
        let frame = Self.dockedFrame(size: size, edge: edge, in: area) // clear of the taskbar
        placing = true
        p.setFrameOrigin(frame.origin)
        placing = false
        p.orderFrontRegardless()
        // The folded tab is tiny and floats on top; only the full panel reserves space.
        DesktopLayout.setZone(.widgets, s.widgetsCollapsed ? nil : frame)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            onMainActor { self?.userMoved() }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main
        ) { [weak self, weak p] _ in
            onMainActor {
                guard let self, let p, !self.placing else { return }
                // Content changed size: dock it again at its new size, and keep the strip in sync.
                let area = DesktopLayout.freeArea(of: NSScreen.main ?? p.screen!, excluding: [.widgets, .folders])
                let frame = Self.dockedFrame(size: p.frame.size, edge: Settings.shared.widgetEdge, in: area)
                self.placing = true
                p.setFrameOrigin(frame.origin)
                self.placing = false
                DesktopLayout.setZone(.widgets, Settings.shared.widgetsCollapsed ? nil : frame)
            }
        }
        panel = p
    }

    /// Where the panel sits when docked to `edge`: flush with the edge, centered along it
    /// (the folded tab tucks into the edge's top/right corner).
    private static func dockedFrame(size: NSSize, edge: WidgetEdge, in area: NSRect) -> NSRect {
        let inset: CGFloat = 4
        let origin: NSPoint
        switch edge {
        case .right: origin = NSPoint(x: area.maxX - size.width - inset, y: area.midY - size.height / 2)
        case .left: origin = NSPoint(x: area.minX + inset, y: area.midY - size.height / 2)
        case .top: origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - inset)
        case .bottom: origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + inset)
        }
        var frame = NSRect(origin: origin, size: size)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - size.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - size.height)
        return frame
    }

    /// The user dragged the panel. Once they let go, snap to the nearest edge
    /// (re-orienting if it's a different one) and re-tile everything.
    private func userMoved() {
        guard !placing else { return }
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            onMainActor { self?.snapToNearestEdge() }
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func snapToNearestEdge() {
        guard let panel, let screen = NSScreen.main else { return }
        if NSEvent.pressedMouseButtons != 0 { // still dragging: check again shortly
            userMoved()
            return
        }
        let area = DesktopLayout.freeArea(of: screen, excluding: [.widgets, .folders])
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        // Distance from the panel's center to each edge, relative to the screen's size.
        let distances: [(WidgetEdge, CGFloat)] = [
            (.left, (c.x - area.minX) / area.width), (.right, (area.maxX - c.x) / area.width),
            (.bottom, (c.y - area.minY) / area.height), (.top, (area.maxY - c.y) / area.height),
        ]
        let nearest = distances.min { $0.1 < $1.1 }!.0
        Settings.shared.widgetEdge = nearest
        placed = nil // force a re-dock even if the edge didn't change
        refresh()
        Settings.broadcastChange()
    }
}

/// Lives on the desktop layer like the folders: BELOW app windows, above
/// Finder's icon layer (so it still takes clicks and drags). Its strip is
/// reserved in the tiling map, so the window tiler keeps apps out of it.
final class WidgetPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = DesktopLayer.level(DesktopLayer.folders)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true // drag anywhere that isn't a button; it snaps to the nearest edge
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false } // clicks work; your typing stays in your app
}

// MARK: - Live system numbers

struct BatteryInfo: Equatable {
    var level: Double // 0…1
    var charging: Bool
    var pluggedIn: Bool
}

@MainActor
final class SystemStats: ObservableObject {
    @Published var cpu: Double = 0 // 0…1, all cores
    @Published var memoryUsed: Double = 0
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var battery: BatteryInfo?
    @Published var diskFree: Double = 0
    @Published var diskTotal: Double = 1

    private var lastTicks: [UInt32]?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: PowerState.saving ? 10 : 5, repeats: true) { [weak self] _ in
            onMainActor { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        updateCPU()
        updateMemory()
        updateBattery()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 1)
        }
    }

    /// CPU use = the share of CPU "ticks" since the last check that weren't idle.
    private func updateCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        if let last = lastTicks {
            let delta = zip(ticks, last).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 { cpu = (total - delta[2]) / total }
        }
        lastTicks = ticks
    }

    /// "Used" the way Activity Monitor counts it: app memory + wired + compressed.
    private func updateMemory() {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Double(getpagesize())
        memoryUsed = (Double(vm.internal_page_count) - Double(vm.purgeable_count)
            + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
    }

    private func updateBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { battery = nil; return }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            battery = BatteryInfo(level: Double(current) / Double(max),
                                  charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                  pluggedIn: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            return
        }
        battery = nil // desktop Mac: no battery widget
    }
}

// MARK: - Widgets

/// Open a System Settings pane or an app.
@MainActor
private func openSettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
}

@MainActor
private func openApp(_ bundleID: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

private struct SideWidgetsView: View {
    // Not observed here on purpose: each card watches only what it shows, so the song's
    // once-a-second progress doesn't redraw the calendar, battery, system and storage cards.
    let stats: SystemStats
    let music: MusicNowPlaying
    let collapsed: Bool
    let horizontal: Bool // docked at the top/bottom: cards side by side
    let toggleCollapsed: () -> Void

    var body: some View {
        if collapsed {
            // Folded: a small glass tab. Click to unfold; drag to move.
            Button(action: toggleCollapsed) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 18))
                    .aeroText(opacity: 0.95, glow: 0.7)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                    .background(AeroGlass(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Show widgets")
            .padding(6)
        } else {
            VStack(spacing: 12) {
                // Top bar: drag handle + fold button.
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .aeroText(opacity: 0.55, glow: 0.2)
                        .help("Drag to move")
                    Spacer()
                    Button(action: toggleCollapsed) {
                        Image(systemName: horizontal ? "chevron.up.2" : "chevron.right.2")
                            .font(.system(size: 12, weight: .semibold))
                            .aeroText(opacity: 0.8, glow: 0.4)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Fold widgets into a tab")
                }
                .padding(.horizontal, 6)

                if horizontal {
                    HStack(alignment: .top, spacing: 12) { cards.frame(width: 240) }
                } else {
                    VStack(spacing: 12) { cards }.frame(width: 240)
                }
            }
            .padding(12)
            .background {
                // Live blur re-renders every frame over a moving wallpaper; Battery Saver uses a flat tint.
                if PowerState.saving {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.28))
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial).opacity(0.55)
                }
            }
            .background(AeroGlass(cornerRadius: 28).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(6)
        }
    }

    @ViewBuilder private var cards: some View {
        CalendarWidget()
        NowPlayingSlot(music: music)
        StatsCards(stats: stats)
    }

    /// Memory is sold in binary gigabytes (8 GB = 8 × 1024³ bytes).
    private func ram(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }

    /// Disks are sold in decimal gigabytes, and Finder counts them that way too.
    private func gb(_ bytes: Double) -> String {
        bytes >= 1e12 ? String(format: "%.1f TB", bytes / 1e12) : String(format: "%.0f GB", bytes / 1e9)
    }
}

/// The Now Playing card, when something is playing (watches only the music).
private struct NowPlayingSlot: View {
    @ObservedObject var music: MusicNowPlaying
    var body: some View {
        if music.track != nil, Settings.shared.showNowPlaying { NowPlayingWidget(music: music) }
    }
}

/// Battery, System and Storage (watch only the system numbers, updated every 5–10 s).
private struct StatsCards: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        if let battery = stats.battery {
            BatteryWidget(info: battery)
                .tappable("Open Battery settings") { openSettings("com.apple.Battery-Settings.extension") }
        }
        AeroCard(title: "System") {
            StatRow(label: "CPU", value: stats.cpu, detail: "\(Int((stats.cpu * 100).rounded()))%")
            StatRow(label: "Memory", value: stats.memoryUsed / stats.memoryTotal,
                    detail: "\(ram(stats.memoryUsed)) of \(ram(stats.memoryTotal))")
        }
        .tappable("Open Activity Monitor") { openApp("com.apple.ActivityMonitor") }
        AeroCard(title: "Storage") {
            StatRow(label: "Used", value: 1 - stats.diskFree / stats.diskTotal, detail: "\(gb(stats.diskFree)) free")
        }
        .tappable("Open Storage settings") { openSettings("com.apple.settings.Storage") }
    }

    private func ram(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }
    private func gb(_ bytes: Double) -> String {
        bytes >= 1e12 ? String(format: "%.1f TB", bytes / 1e12) : String(format: "%.0f GB", bytes / 1e9)
    }
}

/// Makes a card clickable, with a hover glow and a little press-in bounce.
private struct Tappable: ViewModifier {
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(hovering ? 0.10 : 0)))
            .shadow(color: .aeroGlow.opacity(hovering ? 0.6 : 0), radius: 10)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture {
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    pressed = false
                    action()
                }
            }
            .help(help)
    }
}

private extension View {
    func tappable(_ help: String, action: @escaping () -> Void) -> some View {
        modifier(Tappable(help: help, action: action))
    }
}

private struct AeroCard<Content: View>: View {
    let title: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    init(title: String, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(aeroFont(size: 11, weight: .semibold))
                    .kerning(1.2)
                    .aeroText(opacity: 0.7, glow: 0.4)
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AeroGlass())
    }
}

private struct StatRow: View {
    let label: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(aeroFont(size: 14)).aeroText()
                Spacer()
                Text(detail).font(aeroFont(size: 13)).monospacedDigit().aeroText(opacity: 0.75, glow: 0.3)
            }
            AeroBar(value: value)
        }
    }
}

private struct BatteryWidget: View {
    let info: BatteryInfo

    var body: some View {
        AeroCard(title: "Battery") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((info.level * 100).rounded()))%")
                    .font(aeroFont(size: 34, weight: .light))
                    .monospacedDigit()
                    .aeroText()
                Spacer()
                Label(info.charging ? "Charging" : info.pluggedIn ? "Plugged in" : "On battery",
                      systemImage: info.charging ? "bolt.fill" : info.pluggedIn ? "powerplug.fill" : "battery.75percent")
                    .font(aeroFont(size: 13))
                    .aeroText(opacity: 0.8, glow: 0.3)
            }
            AeroBar(value: info.level)
        }
    }
}

/// What Music is playing, with Apple Music's looping motion artwork when the
/// album has one (like the Music app), or a gently "breathing" still cover.
private struct NowPlayingWidget: View {
    @ObservedObject var music: MusicNowPlaying
    @State private var breathe = false
    @State private var scrubbing: Double? // seconds, while you drag the bar

    private func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        AeroCard(title: music.isPlaying ? "Now Playing" : "Paused") {
            HStack(alignment: .top, spacing: 12) {
                cover
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .aeroGlow.opacity(0.5), radius: 8)
                    .onTapGesture { music.openMusic() }
                    .help("Open Music")
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.track?.name ?? "").font(aeroFont(size: 14, weight: .semibold)).lineLimit(1).aeroText()
                    Text(music.track?.artist ?? "").font(aeroFont(size: 12)).lineLimit(1).aeroText(opacity: 0.75, glow: 0.3)
                    Spacer(minLength: 4)
                    HStack(spacing: 14) {
                        control("backward.fill", "Previous") { music.previous() }
                        control(music.isPlaying ? "pause.fill" : "play.fill", music.isPlaying ? "Pause" : "Play") { music.playPause() }
                        control("forward.fill", "Next") { music.next() }
                    }
                }
            }
            if let duration = music.track?.duration, duration > 0 {
                // Click or drag anywhere on the bar to jump within the song.
                VStack(spacing: 3) {
                    AeroBar(value: (scrubbing ?? music.position) / duration)
                        .overlay(ScrubArea { fraction, done in
                            scrubbing = fraction * duration
                            if done {
                                music.seek(to: fraction * duration)
                                scrubbing = nil
                            }
                        }.frame(height: 16))
                    HStack {
                        Text(time(scrubbing ?? music.position)).font(aeroFont(size: 10)).monospacedDigit().aeroText(opacity: 0.6, glow: 0.2)
                        Spacer()
                        Text("-" + time(duration - (scrubbing ?? music.position))).font(aeroFont(size: 10)).monospacedDigit()
                            .aeroText(opacity: 0.6, glow: 0.2)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cover: some View {
        if let video = music.motionVideo, !PowerState.saving {
            LoopingVideo(url: video) // Apple Music's motion artwork (a still cover in Battery Saver)
        } else if !music.youtubeVideos.isEmpty, Settings.shared.youtubeLoops, !PowerState.saving {
            YouTubeLoopCover(ids: music.youtubeVideos, playing: music.isPlaying) // a loop from the middle of the song's video
        } else if let artwork = music.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                .scaleEffect(breathe && music.isPlaying && !PowerState.saving ? 1.08 : 1) // slow "live" drift; off in Battery Saver
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: breathe)
                .onAppear { breathe = true }
        } else {
            ZStack {
                LinearGradient(colors: [.aeroGlow.opacity(0.6), .aeroBlue.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note").font(.system(size: 26)).aeroText()
            }
        }
    }

    private func control(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).aeroText(opacity: 0.95, glow: 0.6).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An invisible strip over the progress bar that turns clicks and drags into a
/// position (0…1). It's a real AppKit view so a drag here scrubs the song
/// instead of moving the whole widget panel.
private struct ScrubArea: NSViewRepresentable {
    let onScrub: (_ fraction: Double, _ done: Bool) -> Void

    func makeNSView(context: Context) -> Strip { Strip(onScrub: onScrub) }
    func updateNSView(_ view: Strip, context: Context) { view.onScrub = onScrub }

    final class Strip: NSView {
        var onScrub: (Double, Bool) -> Void
        init(onScrub: @escaping (Double, Bool) -> Void) {
            self.onScrub = onScrub
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        private func fraction(_ event: NSEvent) -> Double {
            let x = convert(event.locationInWindow, from: nil).x
            return min(max(Double(x / max(bounds.width, 1)), 0), 1)
        }
        override func mouseDown(with event: NSEvent) { onScrub(fraction(event), false) }
        override func mouseDragged(with event: NSEvent) { onScrub(fraction(event), false) }
        override func mouseUp(with event: NSEvent) { onScrub(fraction(event), true) }
    }
}

/// Month calendar. ‹ › flip months, "Today" jumps back, the month name opens Calendar.
private struct CalendarWidget: View {
    @State private var monthOffset = 0

    var body: some View {
        TimelineView(.everyMinute) { context in
            let cal = Calendar.current
            let today = context.date
            let shown = cal.date(byAdding: .month, value: monthOffset, to: today) ?? today
            let days = Self.monthGrid(for: shown, calendar: cal)

            AeroCard(title: shown.formatted(.dateTime.month(.wide).year()), accessory: AnyView(nav)) {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(Self.weekdayInitials(cal).enumerated()), id: \.offset) { _, initial in
                        Text(initial).font(aeroFont(size: 11, weight: .semibold)).aeroText(opacity: 0.55, glow: 0.2)
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        if let day {
                            DayCell(day: day, isToday: cal.isDate(day, inSameDayAs: today))
                        } else {
                            Color.clear.frame(width: 26, height: 26)
                        }
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: monthOffset)
            }
            .overlay(alignment: .topLeading) {
                // The month title doubles as a button that opens Calendar.
                Color.clear.frame(width: 150, height: 34).contentShape(Rectangle())
                    .onTapGesture { openApp("com.apple.iCal") }
                    .help("Open Calendar")
            }
        }
    }

    private var nav: some View {
        HStack(spacing: 2) {
            if monthOffset != 0 {
                navButton("Today", help: "Back to this month") { monthOffset = 0 }
            }
            navButton("chevron.left", help: "Previous month") { monthOffset -= 1 }
            navButton("chevron.right", help: "Next month") { monthOffset += 1 }
        }
    }

    private func navButton(_ symbolOrText: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbolOrText.hasPrefix("chevron") {
                    Image(systemName: symbolOrText).font(.system(size: 11, weight: .bold))
                } else {
                    Text(symbolOrText).font(aeroFont(size: 11, weight: .semibold))
                }
            }
            .aeroText(opacity: 0.85, glow: 0.4)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Capsule().fill(.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Weekday initials starting on the user's first weekday (S M T W T F S).
    private static func weekdayInitials(_ cal: Calendar) -> [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Every day of the month, padded with `nil` so day 1 lands on the right weekday.
    private static func monthGrid(for date: Date, calendar cal: Calendar) -> [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: date),
              let count = cal.range(of: .day, in: .month, for: date)?.count else { return [] }
        let lead = (cal.component(.weekday, from: interval.start) - cal.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
        return Array(repeating: nil, count: lead) + days
    }
}

private struct DayCell: View {
    let day: Date
    let isToday: Bool
    @State private var hovering = false

    var body: some View {
        Text("\(Calendar.current.component(.day, from: day))")
            .font(aeroFont(size: 13, weight: isToday ? .semibold : .regular))
            .monospacedDigit()
            .aeroText(opacity: isToday ? 1 : 0.85, glow: isToday ? 0.9 : 0.25)
            .frame(width: 26, height: 26)
            .background {
                if isToday { // a glossy aqua bubble on today
                    Circle()
                        .fill(LinearGradient(colors: [.aeroGlow, .aeroBlue], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.55), .clear],
                                                              startPoint: .top, endPoint: .center)))
                        .shadow(color: .aeroGlow.opacity(0.7), radius: 5)
                } else if hovering {
                    Circle().fill(.white.opacity(0.15))
                }
            }
            .onHover { hovering = $0 }
    }
}
