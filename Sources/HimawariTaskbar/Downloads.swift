import AppKit
import HimawariKit
import SwiftUI

/// The Downloads stack, like the one on the Mac Dock, but as a Windows XP
/// Explorer window popping up from the taskbar:
///
///   ┌─ 📁 Downloads ─────────────────────── [✕] ┐  Luna blue title bar
///   │ File Tasks     │ 📄 report.pdf             │
///   │  Open folder   │    Today 3:04 AM · 1.2 MB │  newest first; click to open,
///   │  Show newest   │ 🖼 photo.png              │  right-click for more
///   │                │    …                      │
///   ├────────────────┴───────────────────────────┤
///   │ 24 items                                    │  beige status bar
///   └─────────────────────────────────────────────┘
///
/// Click outside it, press Esc, or click ✕ to close.
@MainActor
final class DownloadsWindow {
    private var panel: DownloadsPanel?
    var isOpen: Bool { panel != nil }
    private var outsideClick: Any?
    private let store = DownloadsStore()

    /// `anchor` = the taskbar button's frame, in screen coordinates.
    func toggle(from anchor: NSRect) {
        if panel != nil { close(); return }
        store.reload()
        let size = NSSize(width: 460, height: 440)
        guard let screen = NSScreen.main else { return }
        // Right edge lines up with the button, kept on screen, sitting on top of the taskbar.
        var x = anchor.maxX - size.width
        x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        let p = DownloadsPanel()
        p.contentView = FirstClickHostingView(rootView: DownloadsView(store: store, close: { [weak self] in self?.close() }))
        p.setFrame(NSRect(x: x, y: anchor.maxY + 2, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        panel = p
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            onMainActor { self?.close() }
        }
    }

    func close() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class DownloadsPanel: NSPanel {
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

// MARK: - Reading ~/Downloads

struct Download: Identifiable, Equatable {
    let url: URL
    let added: Date
    let size: Int64?
    let isFolder: Bool
    var id: URL { url }
}

@MainActor
final class DownloadsStore: ObservableObject {
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    @Published private(set) var items: [Download] = []
    @Published private(set) var total = 0

    /// Newest first, like the Dock's stack (sorted by Date Added). Read on a
    /// background thread: the first read asks macOS for permission.
    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey, .isPackageKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
            let all = urls.map { url -> Download in
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
                return Download(url: url, added: v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast,
                                size: isFolder ? nil : v?.fileSize.map(Int64.init), isFolder: isFolder)
            }
            .sorted { $0.added > $1.added }
            DispatchQueue.main.async { [weak self] in
                self?.items = Array(all.prefix(60))
                self?.total = all.count
            }
        }
    }
}

// MARK: - The window

private extension Luna {
    static let title = LinearGradient(stops: [
        .init(color: Color(hex: 0x3D95FF), location: 0), .init(color: Color(hex: 0x0A6AF3), location: 0.1),
        .init(color: Color(hex: 0x0058EE), location: 0.5), .init(color: Color(hex: 0x0054E3), location: 0.85),
        .init(color: Color(hex: 0x0046C8), location: 1),
    ], startPoint: .top, endPoint: .bottom)
    static let frameBlue = Color(hex: 0x0831D9)
    static let taskPane = LinearGradient(colors: [Color(hex: 0x7BA2E7), Color(hex: 0x6375D6)], startPoint: .top, endPoint: .bottom)
    static let beige = Color(hex: 0xECE9D8)
}

private struct DownloadsView: View {
    @ObservedObject var store: DownloadsStore
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                taskPane
                list
            }
            statusBar
        }
        .background(Luna.frameBlue)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
        .onExitCommand(perform: close)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: DownloadsStore.folder.path)).resizable().frame(width: 16, height: 16)
            Text("Downloads").font(Luna.font(13, bold: true)).lunaText()
            Spacer()
            CloseButton(action: close)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(Luna.title)
    }

    private var taskPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File Tasks").font(Luna.font(11, bold: true)).foregroundStyle(Color(hex: 0x215DC6))
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(LinearGradient(colors: [.white, Color(hex: 0xC6D3F7)], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 8) {
                TaskLink(symbol: "folder.fill", title: "Open Downloads folder") {
                    NSWorkspace.shared.open(DownloadsStore.folder); close()
                }
                TaskLink(symbol: "magnifyingglass", title: "Show newest in Finder") {
                    if let newest = store.items.first { NSWorkspace.shared.activateFileViewerSelecting([newest.url]) }
                    close()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0xD6DFF7))
            Spacer()
        }
        .padding(10)
        .frame(width: 150)
        .background(Luna.taskPane)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.items) { item in
                    DownloadRow(item: item, close: close)
                }
                if store.items.isEmpty {
                    Text("This folder is empty.").font(Luna.font(11)).foregroundStyle(.gray).padding(20)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.white)
    }

    private var statusBar: some View {
        HStack {
            Text(store.total == store.items.count ? "\(store.total) items" : "\(store.items.count) newest of \(store.total) items")
                .font(Luna.font(11)).foregroundStyle(.black)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Luna.beige)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xACA899)).frame(height: 1) }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 3).fill(LinearGradient(
                    colors: hovering ? [Color(hex: 0xF08D78), Color(hex: 0xD8492F)] : [Color(hex: 0xE0644A), Color(hex: 0xC2352A)],
                    startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
    }
}

private struct TaskLink: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color(hex: 0x215DC6))
                Text(title).font(Luna.font(11)).foregroundStyle(Color(hex: hovering ? 0x428EFF : 0x215DC6))
                    .underline(hovering).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DownloadRow: View {
    let item: Download
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
            close()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent).font(Luna.font(11, bold: true)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Luna.font(10)).foregroundStyle(hovering ? .white.opacity(0.85) : Color(hex: 0x6D6D6D))
                }
                .foregroundStyle(hovering ? .white : .black)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(hovering ? Color(hex: 0x316AC5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url); close() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]); close() }
            Divider()
            Button("Move to Trash…") { Trash.confirmAndMove(item.url) } // asks first; restorable from the Trash
        }
        .help(item.url.lastPathComponent)
    }

    private var detail: String {
        let when = Calendar.current.isDateInToday(item.added)
            ? "Today " + item.added.formatted(date: .omitted, time: .shortened)
            : item.added.formatted(date: .abbreviated, time: .shortened)
        guard let size = item.size else { return item.isFolder ? "\(when) · Folder" : when }
        return "\(when) · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
