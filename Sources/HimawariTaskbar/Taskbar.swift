import AppKit
import HimawariKit
import SwiftUI

/// The Windows XP ("Luna") taskbar across the bottom of the screen, in place
/// of the Dock:
///
///   [ start ] [quick launch] [ open app ][ open app ] …   [Downloads] [ tray  3:04 AM ]
///
/// • start (with the Apple logo) opens the XP Start menu.
/// • Quick launch: one click opens Finder, your browser, Ghostty.
/// • One button per open app: click to switch to it, click the active one to
///   hide it (XP's minimize), right-click for Hide / Quit.
/// • Downloads opens an XP-style window of your newest downloads (the Dock's
///   Downloads stack).
/// • The tray clock opens Calendar.
///
/// It sits above app windows, and its strip is reserved in DesktopLayout so
/// the window tiler keeps apps from sliding under it.
@MainActor
final class Taskbar {
    /// Exactly the strip the (tiny) real Dock reserves at the bottom, so the bar
    /// covers it and app windows stop right above the bar. 34 until the Dock is in place.
    static var height: CGFloat {
        guard let screen = NSScreen.main else { return 34 }
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        return reserved >= 20 ? reserved : 34
    }

    private var panel: NSPanel?
    private let model = TaskbarModel()
    private let startMenu = StartMenu()
    private let downloads = DownloadsWindow()
    private var placedFrame: NSRect?

    // Full-screen apps: like the Dock, the bar gets out of the way, and slides back
    // while the pointer is pushed against the bottom edge of the screen.
    private var inFullScreen = false
    private var revealed = false
    private var edgeWatch: Timer?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Let the Space-switch animation finish before looking at the windows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    onMainActor { self?.updateFullScreen() }
                }
            }
        }
    }

    private func updateFullScreen() {
        guard let panel else { return }
        inFullScreen = FullScreen.frontAppIsFullScreen()
        if inFullScreen {
            if !revealed { panel.orderOut(nil) }
            if edgeWatch == nil {
                edgeWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    onMainActor { self?.watchBottomEdge() }
                }
            }
        } else {
            edgeWatch?.invalidate()
            edgeWatch = nil
            revealed = false
            panel.orderFrontRegardless()
        }
    }

    private func watchBottomEdge() {
        guard let panel, let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        if !revealed, mouse.y <= screen.frame.minY + 1 {
            revealed = true
            panel.orderFrontRegardless()
        } else if revealed, mouse.y > screen.frame.minY + Self.height + 60, !startMenu.isOpen, !downloads.isOpen {
            revealed = false
            panel.orderOut(nil)
        }
    }

    func refresh() {
        guard Settings.shared.showTaskbar, let screen = NSScreen.main else {
            panel?.orderOut(nil)
            panel = nil
            placedFrame = nil
            startMenu.close()
            downloads.close()
            DesktopLayout.setZone(.taskbar, nil)
            return
        }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: Self.height)
        if panel != nil, placedFrame == frame { return }

        let p = panel ?? Self.makePanel()
        if panel == nil {
            p.contentView = FirstClickHostingView(rootView: TaskbarView(model: model, openStart: { [weak self] in
                self?.toggleStartMenu()
            }, openDownloads: { [weak self] rectInBar in
                self?.toggleDownloads(rectInBar)
            }))
        }
        p.setFrame(frame, display: true)
        if !inFullScreen || revealed { p.orderFrontRegardless() }
        panel = p
        placedFrame = frame
        DesktopLayout.setZone(.taskbar, frame)
    }

    /// Also called when you tap ⌥ Option (sent by the Desktop Hotkeys service).
    func toggleStartMenu() {
        guard let panel else { return }
        downloads.close()
        startMenu.toggle(above: panel.frame)
    }

    /// `rect` is the Downloads button in the bar's own (top-left origin) coordinates.
    private func toggleDownloads(_ rect: CGRect) {
        guard let panel else { return }
        startMenu.close()
        let onScreen = NSRect(x: panel.frame.minX + rect.minX, y: panel.frame.maxY - rect.maxY,
                              width: rect.width, height: rect.height)
        downloads.toggle(from: NSRect(x: onScreen.minX, y: panel.frame.minY, width: onScreen.width, height: panel.frame.height))
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true // (this resets the level, so set the level after it)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1) // just above the real (tiny) Dock
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = true
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        return p
    }
}

// MARK: - Open apps

struct TaskApp: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    var id: pid_t { pid }
    static func == (a: TaskApp, b: TaskApp) -> Bool { a.pid == b.pid && a.name == b.name }
}

@MainActor
final class TaskbarModel: ObservableObject {
    @Published private(set) var apps: [TaskApp] = []
    @Published private(set) var activePID: pid_t?
    @Published private(set) var hidden: Set<pid_t> = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                onMainActor { self?.update() }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            onMainActor {
                if let url = app?.bundleURL { StartMenuData.recordUse(url) } // feeds the Start menu's "frequently used"
            }
        }
        update()
    }

    private func update() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) } // open order, like XP
        let fresh = running.map { TaskApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", icon: $0.icon) }
        if fresh != apps { apps = fresh }
        activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hidden = Set(running.filter(\.isHidden).map(\.processIdentifier))
    }

    /// XP behavior: click a background app to bring it forward; click the active one to minimize (hide) it.
    /// Bringing it forward works like clicking its Dock icon: macOS sends the app a
    /// "reopen", which restores a minimized window (minimized windows would
    /// otherwise be stuck in the Dock, which is under the taskbar).
    func click(_ task: TaskApp) {
        guard let app = NSRunningApplication(processIdentifier: task.pid) else { return }
        if app.isActive && !app.isHidden && Self.hasVisibleWindow(task.pid) {
            app.hide()
            return
        }
        app.unhide()
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }

    private static func hasVisibleWindow(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.width ?? 0) > 80
        }
    }

    func hide(_ task: TaskApp) { NSRunningApplication(processIdentifier: task.pid)?.hide() }
    func quit(_ task: TaskApp) { NSRunningApplication(processIdentifier: task.pid)?.terminate() }
}

// MARK: - Luna look

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Luna {
    static let bar = LinearGradient(stops: [
        .init(color: Color(hex: 0x3E8CF0), location: 0), .init(color: Color(hex: 0x2A6EE3), location: 0.08),
        .init(color: Color(hex: 0x245EDC), location: 0.45), .init(color: Color(hex: 0x2156D4), location: 0.88),
        .init(color: Color(hex: 0x1941A5), location: 1),
    ], startPoint: .top, endPoint: .bottom)
    static let start = LinearGradient(stops: [
        .init(color: Color(hex: 0x6DD35B), location: 0), .init(color: Color(hex: 0x3FA636), location: 0.12),
        .init(color: Color(hex: 0x379E2D), location: 0.5), .init(color: Color(hex: 0x2F8A25), location: 0.88),
        .init(color: Color(hex: 0x1F6E18), location: 1),
    ], startPoint: .top, endPoint: .bottom)
    static let task = LinearGradient(colors: [Color(hex: 0x4B90F5), Color(hex: 0x3C81F3), Color(hex: 0x1F63E1)],
                                     startPoint: .top, endPoint: .bottom)
    static let taskActive = LinearGradient(colors: [Color(hex: 0x1941A5), Color(hex: 0x1E4FC0), Color(hex: 0x2A5FD0)],
                                           startPoint: .top, endPoint: .bottom)
    static let tray = LinearGradient(stops: [
        .init(color: Color(hex: 0x1AA1EF), location: 0), .init(color: Color(hex: 0x139EE9), location: 0.1),
        .init(color: Color(hex: 0x0F8FE0), location: 0.5), .init(color: Color(hex: 0x0C59B9), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "Tahoma-Bold" : "Tahoma", size: size) }
}

extension View {
    /// XP's crisp dark text shadow on white labels.
    func lunaText() -> some View { foregroundStyle(.white).shadow(color: .black.opacity(0.55), radius: 0, x: 1, y: 1) }
}

// MARK: - The bar

private struct TaskbarView: View {
    @ObservedObject var model: TaskbarModel
    let openStart: () -> Void
    let openDownloads: (CGRect) -> Void

    var body: some View {
        HStack(spacing: 0) {
            StartButton(action: openStart)
            QuickLaunch()
            // The grip between quick launch and the task buttons.
            Rectangle().fill(Color(hex: 0x1A4BB8)).frame(width: 1).padding(.vertical, 5)
            Rectangle().fill(Color(hex: 0x5A9BF5)).frame(width: 1).padding(.vertical, 5)
            // XP sizing: wide buttons when few apps are open, narrower as more open,
            // icon-only when it gets really crowded.
            GeometryReader { geo in
                let count = CGFloat(max(model.apps.count, 1))
                let width = min(160, max(30, (geo.size.width - 10 - 3 * (count - 1)) / count))
                HStack(spacing: 3) {
                    ForEach(model.apps) { task in
                        TaskButton(task: task, active: model.activePID == task.pid && !model.hidden.contains(task.pid),
                                   model: model, width: width)
                    }
                }
                .padding(.horizontal, 5)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: width)
            }
            DownloadsButton(open: openDownloads)
            Tray()
        }
        .frame(maxHeight: .infinity)
        .background(Luna.bar)
    }
}

private struct StartButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 0, x: 1, y: 1)
                Text("start")
                    .font(.custom("Trebuchet-BoldItalic", size: 19))
                    .lunaText()
            }
            .padding(.leading, 12)
            .padding(.trailing, 22)
            .frame(maxHeight: .infinity)
            .background(Luna.start.brightness(hovering ? 0.08 : 0))
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start")
    }
}

private struct QuickLaunch: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Apps.quickLaunch, id: \.self) { url in
                Button { Apps.open(url) } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(url.deletingPathExtension().lastPathComponent)
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct TaskButton: View {
    let task: TaskApp
    let active: Bool
    let model: TaskbarModel
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        Button { model.click(task) } label: {
            HStack(spacing: 6) {
                if let icon = task.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                if width >= 56 { // too narrow for a name: icon only (the tooltip still has it)
                    Text(task.name).font(Luna.font(11, bold: active)).lineLimit(1).lunaText()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, width >= 56 ? 7 : 0)
            .frame(width: width, height: 26, alignment: width >= 56 ? .leading : .center)
            .background(active ? Luna.taskActive : Luna.task)
            .brightness(hovering && !active ? 0.06 : 0)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: active ? 0x10327D : 0x1A4BC0), lineWidth: 1))
            .overlay(alignment: .top) { // XP's highlight line on raised buttons
                if !active { Rectangle().fill(.white.opacity(0.25)).frame(height: 1).padding(.horizontal, 2).padding(.top, 1) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(active ? "Minimize (Hide)" : "Restore") { active ? model.hide(task) : model.click(task) }
            Divider()
            Button("Close \(task.name)") { model.quit(task) }
        }
        .help(task.name)
    }
}

/// Opens the XP Downloads window (the Dock's Downloads stack, XP style).
private struct DownloadsButton: View {
    let open: (CGRect) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            Button { open(geo.frame(in: .global)) } label: {
                HStack(spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: DownloadsStore.folder.path)).resizable().frame(width: 20, height: 20)
                    Text("Downloads").font(Luna.font(11)).lunaText()
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(hovering ? 0.18 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 104)
        .help("Downloads")
    }
}

private struct Tray: View {
    var body: some View {
        HStack(spacing: 10) {
            Button { Apps.open(bundleID: "com.mitchellh.ghostty") } label: {
                Image(systemName: "terminal.fill").font(.system(size: 13)).lunaText()
            }
            .buttonStyle(.plain)
            .help("Ghostty (⌘⌃T)")
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(Luna.font(11))
                    .lunaText()
                    .help(context.date.formatted(date: .complete, time: .omitted))
            }
            .onTapGesture { Apps.open(bundleID: "com.apple.iCal") }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Luna.tray)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0x0B3F8F)).frame(width: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0x5CC0F8)).frame(width: 1).offset(x: 1) }
    }
}

// MARK: - Launching things

@MainActor
enum Apps {
    static func url(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var browser: URL? { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) }

    static var quickLaunch: [URL] {
        [url("com.apple.finder"), browser, url("com.mitchellh.ghostty")].compactMap { $0 }
    }

    static func open(_ url: URL) {
        if url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func open(bundleID: String) {
        if let url = url(bundleID) { open(url) }
    }
}
