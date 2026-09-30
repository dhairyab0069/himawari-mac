import AppKit
import HanabiKit
import SwiftUI

/// The Windows XP Start menu: pops up above the start button.
///
///   ┌──────────────────────────────────┐
///   │ 👤 Your Name                     │  blue header
///   ├─────────────────┬────────────────┤
///   │ Ghostty         │ My Documents   │
///   │ Firefox         │ My Pictures    │  white: pinned apps   light blue: places
///   │ Finder          │ …              │
///   │ …               │ Control Panel  │
///   │ All Programs ▶  │ Desktop Settings▶
///   ├─────────────────┴────────────────┤
///   │            🔑 Log Off  ⏻ Turn Off │  blue footer
///   └──────────────────────────────────┘
///
/// Click outside it or press Esc to close.
@MainActor
final class StartMenu {
    private var panel: StartPanel?
    var isOpen: Bool { panel != nil }
    private var outsideClick: Any?
    private var keyMonitor: Any?
    private let keyboard = StartKeyboard()

    func toggle(above bar: NSRect) {
        if panel != nil { close(); return }
        let p = StartPanel()
        let size = NSSize(width: 420, height: StartMenuLayout.height())
        StartMenuData.refreshRecentDocuments()
        keyboard.reset()
        p.contentView = FirstClickHostingView(rootView: StartMenuView(
            close: { [weak self] in self?.close() },
            panelFrame: { [weak p] in p?.frame ?? .zero },
            height: size.height)
            .environmentObject(keyboard))
        XPFlyouts.shared.onAction = { [weak self] in self?.close() }
        p.setFrame(NSRect(x: bar.minX, y: bar.maxY, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in // quick fade + rise, like XP
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        panel = p
        // Arrow keys / Enter / Esc drive the menu; any other key types into the search box.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            let used = onMainActor { self?.handleKey(code) ?? false }
            return used ? nil : event
        }
        // A click anywhere else closes it.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            onMainActor { self?.close() }
        }
    }

    func close() {
        XPFlyouts.shared.closeAll()
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Returns true if the key was used (so it doesn't also reach the search box).
    private func handleKey(_ keyCode: Int) -> Bool {
        let flyouts = XPFlyouts.shared
        let inFlyout = flyouts.keyboardDepth != nil
        switch keyCode {
        case 125: inFlyout ? flyouts.keyMove(1) : keyboard.move(1); return true    // ↓
        case 126: inFlyout ? flyouts.keyMove(-1) : keyboard.move(-1); return true  // ↑
        case 124:                                                                  // →
            if inFlyout { return flyouts.keyRight() }
            return keyboard.hasQuery ? false : keyboard.right()                    // (in the search box: move the cursor)
        case 123:                                                                  // ←
            if inFlyout { flyouts.keyLeft(); return true }
            return keyboard.hasQuery ? false : keyboard.left()
        case 36, 76:                                                               // Enter
            if inFlyout { flyouts.keyEnter(); return true }
            return keyboard.activate()                                             // nothing selected: search box opens its top hit
        case 53:                                                                   // Esc: one level at a time
            if flyouts.isOpen { flyouts.closeAll(); return true }
            if keyboard.hasQuery { keyboard.clearQuery(); return true }
            close()
            return true
        default:
            keyboard.selectedID = nil // typing: the search box takes over
            return false
        }
    }
}

/// How tall the Start menu is: tall enough for everything in it, but never
/// taller than the screen above the taskbar. The header and footer (with the
/// power buttons) always keep their full size; only the middle can be clipped.
@MainActor
enum StartMenuLayout {
    static let header: CGFloat = 62
    static let footer: CGFloat = 44

    static func height() -> CGFloat {
        let pinned = CGFloat(StartMenuData.pinned.count) * 38           // 30-pt icons
        let frequentCount = StartMenuData.frequent().count
        let frequent = frequentCount > 0 ? 7 + CGFloat(frequentCount) * 34 : 0
        let left = 16 + pinned + frequent + 7 + 32 + 32                  // padding, rows, divider, All Programs, search box
        let right: CGFloat = 16 + 7 * 32 + 9 + 4 * 32                    // places + recent, divider, 4 system rows
        let wanted = header + max(left, right, 360) + footer
        guard let screen = NSScreen.main else { return wanted }
        let available = screen.visibleFrame.maxY - (screen.frame.minY + Taskbar.height) - 8
        return min(wanted, available)
    }
}

/// Keyboard navigation for the Start menu. Every row registers itself with
/// its on-screen frame; ↑↓ move within a column, ←→ between the two columns,
/// → / Enter on a ▸ row opens its flyout with the keyboard in it.
@MainActor
final class StartKeyboard: ObservableObject {
    struct Entry {
        var frame: CGRect
        var activate: (_ fromKeyboard: Bool) -> Void
        var hasFlyout: Bool
    }

    @Published var selectedID: String?
    var hasQuery = false
    var clearQuery: () -> Void = {}
    private var entries: [String: Entry] = [:]
    private let columnSplit: CGFloat = 210 // left column is 210 wide

    func reset() { selectedID = nil; entries = [:]; hasQuery = false }
    func register(_ id: String, _ entry: Entry) { entries[id] = entry }
    func unregister(_ id: String) { entries[id] = nil }

    private func column(of id: String) -> Int { (entries[id]?.frame.midX ?? 0) < columnSplit ? 0 : 1 }

    private func ids(inColumn c: Int) -> [String] {
        entries.filter { (($0.value.frame.midX) < columnSplit ? 0 : 1) == c }
            .sorted { $0.value.frame.minY < $1.value.frame.minY }
            .map(\.key)
    }

    func move(_ step: Int) {
        guard let current = selectedID, entries[current] != nil else {
            selectedID = step > 0 ? ids(inColumn: 0).first : ids(inColumn: 0).last
            return
        }
        let list = ids(inColumn: column(of: current))
        guard let i = list.firstIndex(of: current) else { return }
        selectedID = list[(i + step + list.count) % list.count] // wraps around
    }

    func right() -> Bool {
        guard let current = selectedID, let entry = entries[current] else { selectedID = ids(inColumn: 0).first; return true }
        if entry.hasFlyout { entry.activate(true); return true }
        if column(of: current) == 0 { selectedID = nearest(to: entry.frame, inColumn: 1) }
        return true
    }

    func left() -> Bool {
        guard let current = selectedID, let entry = entries[current] else { return false }
        if column(of: current) == 1 { selectedID = nearest(to: entry.frame, inColumn: 0) }
        return true
    }

    /// Enter: run the selected row. Returns false if nothing is selected.
    func activate() -> Bool {
        guard let current = selectedID, let entry = entries[current] else { return false }
        entry.activate(true)
        return true
    }

    private func nearest(to frame: CGRect, inColumn c: Int) -> String? {
        ids(inColumn: c).min { abs(entries[$0]!.frame.midY - frame.midY) < abs(entries[$1]!.frame.midY - frame.midY) }
    }
}

private final class StartPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }
    override var canBecomeKey: Bool { true } // for Esc; nonactivating, so your app keeps focus
}

// MARK: - Contents

private struct StartMenuView: View {
    let close: () -> Void
    let panelFrame: () -> NSRect
    var height: CGFloat = 540
    @EnvironmentObject private var keyboard: StartKeyboard
    @State private var showPower = false
    @State private var query = ""
    @StateObject private var search = StartSearch()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: StartMenuLayout.header)
            Group {
                if showPower {
                    TurnOffView(cancel: { showPower = false }, done: close)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        leftColumn.frame(width: 210).frame(maxHeight: .infinity, alignment: .top).background(Color.white)
                        rightColumn.frame(width: 210).frame(maxHeight: .infinity, alignment: .top).background(Color(hex: 0xD3E5FA))
                            .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0x95BDEE)).frame(width: 1) }
                    }
                }
            }
            // Exactly the space between header and footer; anything taller is clipped here,
            // so it can never push the power buttons out of the menu.
            .frame(height: height - StartMenuLayout.header - StartMenuLayout.footer, alignment: .top)
            .clipped()
            footer.frame(height: StartMenuLayout.footer)
        }
        .frame(height: height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
            .strokeBorder(Color(hex: 0x1C4FB8), lineWidth: 1))
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color(hex: 0x2A6EE3))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.white, Color(hex: 0xD8E6FB)],
                                                                                 startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            Text(NSFullUserName()).font(Luna.font(15, bold: true)).lunaText()
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .background(LinearGradient(colors: [Color(hex: 0x1868CE), Color(hex: 0x0E60CB), Color(hex: 0x3582DE)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The lists get whatever room is left and scroll if they need more,
            // so All Programs and the search box are never pushed out.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        ForEach(StartMenuData.pinned, id: \.self) { url in
                            appRow(url, bold: true, iconSize: 30)
                        }
                        let frequent = StartMenuData.frequent()
                        if !frequent.isEmpty {
                            divider
                            ForEach(frequent, id: \.self) { url in
                                appRow(url, bold: false, iconSize: 26, frequent: true)
                            }
                        }
                    } else {
                        searchResults
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if query.isEmpty {
                divider
                StartRow(symbol: "play.fill", symbolColor: Color(hex: 0x2FA82A), title: "All Programs", bold: true, trailingArrow: true,
                         flyout: flyout(fullHeight: true) { StartItems.allPrograms() }) {}
            }
            searchBox.padding(.bottom, 2)
        }
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle().fill(LinearGradient(colors: [.clear, Color(hex: 0xBBBBBB), .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func appRow(_ url: URL, bold: Bool, iconSize: CGFloat, frequent: Bool = false) -> some View {
        StartRow(icon: NSWorkspace.shared.icon(forFile: url.path), title: url.deletingPathExtension().lastPathComponent,
                 bold: bold, iconSize: iconSize) {
            Apps.open(url); close()
        }
        .xpContextMenu { AppMenu.items(for: url, frequent: frequent) }
    }

    /// Vista/7-style: type to search, right in the Start menu.
    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color(hex: 0x6D6D6D))
            TextField("Search programs and files", text: $query)
                .textFieldStyle(.plain)
                .font(Luna.font(11))
                .foregroundStyle(.black)
                .focused($searchFocused)
                .onSubmit {
                    if let first = search.first { open(first) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(hex: 0x9A9A9A))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(hex: 0x7F9DB9), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .onChange(of: query) { _, text in
            search.update(text)
            keyboard.hasQuery = !text.isEmpty
        }
        .onAppear {
            keyboard.clearQuery = { query = "" }
            DispatchQueue.main.async { searchFocused = true } // just start typing, like Windows 7
        }
    }

    @ViewBuilder private var searchResults: some View {
        if !search.programs.isEmpty {
            resultHeader("Programs")
            ForEach(search.programs, id: \.self) { url in
                StartRow(icon: NSWorkspace.shared.icon(forFile: url.path), title: url.deletingPathExtension().lastPathComponent,
                         bold: url == search.first, iconSize: 22) { open(url) }
                    .xpContextMenu { AppMenu.items(for: url) }
            }
        }
        if !search.files.isEmpty {
            resultHeader("Files")
            ForEach(search.files, id: \.self) { url in
                StartRow(icon: NSWorkspace.shared.icon(forFile: url.path), title: url.lastPathComponent,
                         bold: url == search.first, iconSize: 22) { open(url) }
                    .xpContextMenu { AppMenu.items(forFile: url) }
            }
        }
        if search.programs.isEmpty && search.files.isEmpty {
            Text("No items match your search.").font(Luna.font(11)).foregroundStyle(Color(hex: 0x6D6D6D)).padding(10)
        }
    }

    private func resultHeader(_ title: String) -> some View {
        Text(title).font(Luna.font(11, bold: true)).foregroundStyle(Color(hex: 0x1E3287))
            .padding(.horizontal, 10).padding(.top, 4)
    }

    private func open(_ url: URL) {
        if url.pathExtension == "app" { Apps.open(url) } else { NSWorkspace.shared.open(url) }
        close()
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(StartItems.places, id: \.title) { place in
                StartRow(icon: NSWorkspace.shared.icon(forFile: place.url.path), title: place.title, bold: true, textColor: Color(hex: 0x0A246A)) {
                    NSWorkspace.shared.open(place.url); close()
                }
                if place.title == "My Documents" {
                    StartRow(symbol: "clock.arrow.circlepath", symbolColor: Color(hex: 0x2A6EE3), title: "My Recent Documents",
                             bold: true, textColor: Color(hex: 0x0A246A), trailingArrow: true,
                             flyout: flyout { StartItems.recentDocumentItems() }) {}
                }
            }
            Rectangle().fill(Color(hex: 0xA7C4EB)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
            if let settingsApp = Apps.url("com.apple.systempreferences") {
                StartRow(icon: NSWorkspace.shared.icon(forFile: settingsApp.path), title: "Control Panel", textColor: Color(hex: 0x0A246A)) {
                    Apps.open(settingsApp); close()
                }
            }
            StartRow(symbol: "gearshape.2.fill", symbolColor: Color(hex: 0x2A6EE3), title: "Desktop Settings",
                     textColor: Color(hex: 0x0A246A), trailingArrow: true,
                     flyout: flyout { DesktopSettingsMenu.items() }) {}
            StartRow(symbol: "magnifyingglass", symbolColor: Color(hex: 0x2A6EE3), title: "Spotlight Search", textColor: Color(hex: 0x0A246A)) {
                close(); Keys.spotlight()
            }
            StartRow(symbol: "terminal.fill", symbolColor: Color(hex: 0x333333), title: "Run… (Ghostty)", textColor: Color(hex: 0x0A246A)) {
                close(); Ghostty.newWindow()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    /// Opens an XP menu beside a Start menu row. `rect` is the row in the Start
    /// menu's own (top-left origin) coordinates.
    private func flyout(fullHeight: Bool = false, _ items: @escaping @MainActor () -> [XPMenuItem]) -> (CGRect, Bool) -> Void {
        { rect, fromKeyboard in
            let panel = panelFrame()
            let onScreen = NSRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
            XPFlyouts.shared.open(items(), beside: onScreen, depth: 0, matchHeight: fullHeight ? panel : nil,
                                  selectFirst: fromKeyboard)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            FooterButton(symbol: "key.fill", color: Color(hex: 0xE8A317), title: "Log Off") { Power.logOut(); close() }
            FooterButton(symbol: "power", color: Color(hex: 0xD7401C), title: "Turn Off Computer") { showPower = true }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(LinearGradient(colors: [Color(hex: 0x4282D6), Color(hex: 0x3C7FDC), Color(hex: 0x1C4FB8)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

/// One Start menu entry; highlights XP-blue on hover.
private struct StartRow: View {
    var icon: NSImage? = nil
    var symbol: String? = nil
    var symbolColor: Color = .black
    let title: String
    var bold = false
    var textColor: Color = .black
    var iconSize: CGFloat = 24
    var trailingArrow = false
    /// Rows like All Programs ▸ open an XP menu beside them on hover (or click, → , Enter).
    /// The Bool is true when it was opened from the keyboard.
    var flyout: ((CGRect, Bool) -> Void)? = nil
    let action: () -> Void
    @EnvironmentObject private var keyboard: StartKeyboard
    @State private var hovering = false

    private var lit: Bool { hovering || keyboard.selectedID == title }

    var body: some View {
        GeometryReader { geo in
            row(frame: geo.frame(in: .global))
                .onAppear { register(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, frame in register(frame) }
                .onDisappear { keyboard.unregister(title) }
        }
        .frame(height: iconSize + 8)
    }

    private func register(_ frame: CGRect) {
        let flyout = flyout, action = action
        keyboard.register(title, .init(frame: frame, activate: { fromKeyboard in
            if let flyout { flyout(frame, fromKeyboard) } else { action() }
        }, hasFlyout: flyout != nil))
    }

    private func row(frame: CGRect) -> some View {
        Button {
            if let flyout { flyout(frame, false) } else { action() }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(lit ? .white : symbolColor)
                        .frame(width: iconSize, height: iconSize)
                }
                Text(title).font(Luna.font(12, bold: bold)).foregroundStyle(lit ? .white : textColor).lineLimit(1)
                Spacer(minLength: 0)
                if trailingArrow {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8))
                        .foregroundStyle(lit ? .white : Color(hex: 0x2FA82A))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background(lit ? Color(hex: 0x316AC5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            guard inside else { return }
            keyboard.selectedID = title // mouse and keyboard share one selection
            if let flyout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if hovering { flyout(frame, false) } } // XP-style hover delay
            } else {
                XPFlyouts.shared.closeAll()
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct FooterButton: View {
    let symbol: String
    let color: Color
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.7), lineWidth: 1))
                Text(title).font(Luna.font(12)).lunaText()
            }
            .brightness(hovering ? 0.12 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// XP's "Turn off computer" choice: Stand By / Turn Off / Restart.
private struct TurnOffView: View {
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Turn off computer").font(Luna.font(15, bold: true)).foregroundStyle(Color(hex: 0x0A246A))
            HStack(spacing: 28) {
                choice("moon.fill", Color(hex: 0xE8A317), "Stand By") { Power.sleep() }
                choice("power", Color(hex: 0xD7401C), "Turn Off") { Power.shutDown() }
                choice("arrow.clockwise", Color(hex: 0x2FA82A), "Restart") { Power.restart() }
            }
            Button("Cancel", action: cancel).font(Luna.font(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0xD3E5FA))
    }

    private func choice(_ symbol: String, _ color: Color, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button { done(); action() } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 8).fill(color))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.8), lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                Text(title).font(Luna.font(12)).foregroundStyle(Color(hex: 0x0A246A))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - What's in the menu

@MainActor
enum StartItems {
    /// Default pins (until you pin/unpin yourself): Ghostty, your browser, Finder, then a few common ones.
    static var defaultPinned: [URL] {
        var urls = [Apps.url("com.mitchellh.ghostty"), Apps.browser, Apps.url("com.apple.finder")]
        urls += ["com.microsoft.VSCode", "com.apple.iCal", "com.apple.Notes", "com.apple.Music", "com.apple.ActivityMonitor"]
            .map(Apps.url)
        var seen = Set<URL>()
        return urls.compactMap { $0 }.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    static var places: [(title: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [("My Documents", home.appending(path: "Documents")), ("My Pictures", home.appending(path: "Pictures")),
                ("My Music", home.appending(path: "Music")), ("Downloads", home.appending(path: "Downloads")),
                ("Desktop", home.appending(path: "Desktop")), ("My Computer", URL(fileURLWithPath: "/"))]
    }

    /// "All Programs": every app, as XP menu items (right-click to pin).
    static func allPrograms() -> [XPMenuItem] {
        appURLs().map { url in
            XPMenuItem(title: url.deletingPathExtension().lastPathComponent,
                       icon: NSWorkspace.shared.icon(forFile: url.path),
                       contextMenu: XPSubmenu { AppMenu.items(for: url) }) { Apps.open(url) }
        }
    }

    static func recentDocumentItems() -> [XPMenuItem] {
        let docs = StartMenuData.recentDocuments
        guard !docs.isEmpty else { return [XPMenuItem(title: "(No recent documents)", enabled: false)] }
        return docs.map { url in
            XPMenuItem(title: url.lastPathComponent, icon: NSWorkspace.shared.icon(forFile: url.path),
                       contextMenu: XPSubmenu { AppMenu.items(forFile: url) }) { NSWorkspace.shared.open(url) }
        } + [.separator, XPMenuItem(title: "Open Recents in Finder", symbol: "clock") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/Recents.app"))
        }]
    }

    /// Every app in /Applications, ~/Applications and /System/Applications, A–Z.
    static func appURLs() -> [URL] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       fm.homeDirectoryForCurrentUser.appending(path: "Applications").path]
        let apps = folders.flatMap { folder in
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appending(path: $0) }
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Power

@MainActor
enum Power {
    static func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }
    // Apple events to loginwindow: macOS shows its usual "Are you sure?" confirmation.
    static func shutDown() { loginwindow("aevtrsdn") }
    static func restart() { loginwindow("aevtrrst") }
    static func logOut() { loginwindow("aevtrlgo") }

    private static func loginwindow(_ event: String) {
        run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event \(event)»"])
    }

    static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }
}
