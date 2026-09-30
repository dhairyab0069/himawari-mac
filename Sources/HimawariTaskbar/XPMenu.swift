import AppKit
import HimawariKit
import SwiftUI

/// Windows XP cascading menus: white, grey border, Tahoma, blue highlight.
/// They fly out to the right of whatever opened them when you hover (like
/// Windows), submenus cascade further right, and they never run under the
/// taskbar or off the screen. Used for Start ▸ All Programs and
/// Start ▸ Desktop Settings.
struct XPMenuItem: Identifiable {
    let id = UUID()
    var title = ""
    var icon: NSImage?
    var symbol: String?
    var checked = false
    var enabled = true
    var isSeparator = false
    var submenu: XPSubmenu?
    var contextMenu: XPSubmenu? // right-click menu for this row (e.g. Pin to Start menu)
    var action: (@MainActor () -> Void)? // the only closure, so `XPMenuItem(title: …) { … }` sets the action

    static var separator: XPMenuItem { XPMenuItem(isSeparator: true) }

    var height: CGFloat { isSeparator ? 9 : 24 }
    var isSelectable: Bool { !isSeparator && enabled }
}

/// A submenu's items, built when it opens (so checkmarks are current).
struct XPSubmenu {
    let make: @MainActor () -> [XPMenuItem]
    init(_ make: @escaping @MainActor () -> [XPMenuItem]) { self.make = make }
}

/// The open flyouts, one per depth (0 = next to the Start menu, 1 = its submenu, …).
/// Mouse and keyboard share one selection per flyout: ↑↓ move, → opens a
/// submenu, ← closes back out, Enter runs the item.
@MainActor
final class XPFlyouts: ObservableObject {
    static let shared = XPFlyouts()
    /// Called after a menu item runs, so the Start menu can close too.
    var onAction: (() -> Void)?
    /// Highlighted row per depth.
    @Published var selection: [Int: Int] = [:]
    /// Which flyout the arrow keys are driving (nil = the Start menu itself).
    private(set) var keyboardDepth: Int?
    private var stack: [NSPanel] = []
    private var itemsAt: [Int: [XPMenuItem]] = [:]
    private var rowFrames: [Int: [Int: NSRect]] = [:]

    var isOpen: Bool { !stack.isEmpty }

    /// Open `items` beside `anchor` (a row's frame, in screen coordinates).
    /// `matchHeight`: make the flyout exactly as tall as this frame (All Programs
    /// matches the Start menu). `selectFirst`: opened from the keyboard.
    func open(_ items: [XPMenuItem], beside anchor: NSRect, depth: Int, width: CGFloat = 250,
              matchHeight: NSRect? = nil, selectFirst: Bool = false) {
        close(from: depth)
        guard let screen = NSScreen.main else { return }
        let floor = screen.frame.minY + Taskbar.height            // never under the taskbar
        let maxHeight = matchHeight?.height ?? (screen.visibleFrame.maxY - floor - 8)
        let contentHeight = items.reduce(6) { $0 + $1.height }
        let size = NSSize(width: width, height: matchHeight?.height ?? min(contentHeight, maxHeight))

        // Right of the anchor, top edges lined up (XP overlaps by a few pixels);
        // flip to the left if there's no room, and push up off the taskbar.
        var x = anchor.maxX - 3
        if x + size.width > screen.frame.maxX { x = anchor.minX - size.width + 3 }
        var y = anchor.maxY - size.height
        y = max(y, floor)
        y = min(y, screen.visibleFrame.maxY - size.height)
        if let matchHeight { y = matchHeight.minY }
        itemsAt[depth] = items
        selection[depth] = selectFirst ? items.firstIndex(where: \.isSelectable) : nil
        if selectFirst { keyboardDepth = depth }

        let panel = XPFlyoutPanel()
        panel.contentView = FirstClickHostingView(rootView: XPMenuView(
            items: items, depth: depth, scrolls: contentHeight > maxHeight,
            panelFrame: { [weak panel] in panel?.frame ?? .zero }))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in // XP's quick fade-in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
        stack.append(panel)
    }

    func close(from depth: Int) {
        while stack.count > depth { stack.removeLast().orderOut(nil) }
        for d in Array(itemsAt.keys) where d >= depth {
            itemsAt[d] = nil
            rowFrames[d] = nil
            selection[d] = nil
        }
        if let k = keyboardDepth, k >= depth { keyboardDepth = depth > 0 ? depth - 1 : nil }
    }

    func setFrame(_ frame: NSRect, depth: Int, index: Int) { rowFrames[depth, default: [:]][index] = frame }

    // MARK: Keyboard

    func keyMove(_ step: Int) {
        guard let depth = keyboardDepth, let items = itemsAt[depth], !items.isEmpty else { return }
        var i = selection[depth] ?? (step > 0 ? -1 : items.count)
        for _ in items.indices {
            i = (i + step + items.count) % items.count // wraps around, like Windows
            if items[i].isSelectable { selection[depth] = i; return }
        }
    }

    /// → : open the selected item's submenu. Returns false if there's nothing to open.
    func keyRight() -> Bool {
        guard let depth = keyboardDepth, let i = selection[depth], let item = itemsAt[depth]?[i],
              let submenu = item.submenu, let frame = rowFrames[depth]?[i] else { return false }
        open(submenu.make(), beside: frame, depth: depth + 1, width: 220, selectFirst: true)
        return true
    }

    /// ← : close the deepest flyout; from the first one, go back to the Start menu.
    func keyLeft() {
        guard let depth = keyboardDepth else { return }
        close(from: depth)
    }

    func keyEnter() {
        guard let depth = keyboardDepth, let i = selection[depth], let item = itemsAt[depth]?[i], item.enabled else { return }
        if item.submenu != nil {
            _ = keyRight()
        } else if let action = item.action {
            didRunAction()
            action()
        }
    }

    func closeAll() { close(from: 0) }

    fileprivate func didRunAction() {
        closeAll()
        onAction?()
    }
}

private final class XPFlyoutPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1) // above the Start menu
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }
}

private struct XPMenuView: View {
    let items: [XPMenuItem]
    let depth: Int
    let scrolls: Bool
    let panelFrame: () -> NSRect

    @ObservedObject private var flyouts = XPFlyouts.shared

    var body: some View {
        Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) { rows }
                        .onChange(of: flyouts.selection[depth]) { _, index in
                            if let index { proxy.scrollTo(index) } // keyboard selection stays visible
                        }
                }
            } else {
                rows
            }
        }
        .padding(.vertical, 3)
        .background(Color.white)
        .overlay(Rectangle().strokeBorder(Color(hex: 0xACA899), lineWidth: 1))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.isSeparator {
                    Rectangle().fill(Color(hex: 0xACA899)).frame(height: 1).padding(.horizontal, 3).padding(.vertical, 4)
                } else {
                    XPMenuRow(item: item, index: index, depth: depth, panelFrame: panelFrame).id(index)
                }
            }
        }
    }
}

private struct XPMenuRow: View {
    let item: XPMenuItem
    let index: Int
    let depth: Int
    let panelFrame: () -> NSRect
    @ObservedObject private var flyouts = XPFlyouts.shared
    @State private var hovering = false

    private var lit: Bool { item.enabled && (hovering || flyouts.selection[depth] == index) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 6) {
                // Left margin: checkmark, or the item's icon.
                ZStack {
                    if item.checked {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    } else if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else if let symbol = item.symbol {
                        Image(systemName: symbol).font(.system(size: 11))
                    }
                }
                .frame(width: 20)
                Text(item.title).font(Luna.font(11)).lineLimit(1)
                Spacer(minLength: 0)
                if item.submenu != nil {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                }
            }
            .foregroundStyle(!item.enabled ? Color(hex: 0xACA899) : lit ? .white : .black)
            .padding(.horizontal, 6)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(lit ? Color(hex: 0x316AC5) : .clear)
            .contentShape(Rectangle())
            .onAppear { reportFrame(geo.frame(in: .global)) }
            .onChange(of: geo.frame(in: .global)) { _, frame in reportFrame(frame) }
            .onHover { inside in
                hovering = inside
                guard inside, item.enabled else { return }
                flyouts.selection[depth] = index // the mouse moves the keyboard selection too
                if item.submenu != nil {
                    // Open the submenu after a short pause, like Windows.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if hovering { openSubmenu(geo.frame(in: .global)) }
                    }
                } else {
                    XPFlyouts.shared.close(from: depth + 1) // moved off a submenu parent
                }
            }
            .onTapGesture {
                guard item.enabled else { return }
                if item.submenu != nil {
                    openSubmenu(geo.frame(in: .global))
                } else if let action = item.action {
                    XPFlyouts.shared.didRunAction()
                    action()
                }
            }
        }
        .frame(height: item.height)
        .padding(.horizontal, 2)
        .overlay {
            if let menu = item.contextMenu {
                RightClickCatcher { point in
                    onMainActor {
                        XPFlyouts.shared.open(menu.make(), beside: NSRect(origin: point, size: .zero), depth: depth + 1, width: 210)
                    }
                }
            }
        }
    }

    /// Remember where this row is on screen, so → can open its submenu beside it.
    private func reportFrame(_ rect: CGRect) {
        let panel = panelFrame()
        flyouts.setFrame(NSRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height),
                         depth: depth, index: index)
    }

    /// `rect` is this row in the flyout's own (top-left origin) coordinates.
    private func openSubmenu(_ rect: CGRect) {
        guard let submenu = item.submenu else { return }
        let panel = panelFrame()
        let onScreen = NSRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
        XPFlyouts.shared.open(submenu.make(), beside: onScreen, depth: depth + 1, width: 220)
    }
}
