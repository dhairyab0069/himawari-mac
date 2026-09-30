import AppKit
import HimawariKit
import SwiftUI
import UniformTypeIdentifiers

/// iOS-style folders down one side of the desktop.
///
/// Every real folder on your Desktop is shown as an iOS folder (with a 3×3
/// preview of what's inside), and any loose files are grouped by type. Make a
/// new folder on the Desktop and it appears within about a second. Click a
/// folder: it zooms open from its icon into a big blurred panel. Click a file
/// to open it, click a folder inside to zoom into that one (‹ goes back),
/// right-click for Show in Finder, and click outside or press Esc to close.
/// Drag a tile onto another to rearrange them; the order is remembered.
///
/// Runs as its own background service (HimawariFolders), separate from the
/// wallpaper. The folders take the side opposite the widgets, and their strip
/// is reserved in DesktopLayout, so tiled app windows stay clear of it.
@MainActor
final class FileFolders {
    private var dock: DesktopWindow?
    private var overlay: DesktopWindow?
    private let store = FolderStore()
    private var timer: Timer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var placed: (zone: NSRect, sources: [URL])? // what's on screen now

    static let dockWidth: CGFloat = 220

    /// Force a full redraw (Battery Saver changed how tiles are drawn).
    func rebuild() {
        placed = nil
        refresh()
    }

    /// Show / move / hide the folders to match the settings and the tiling map.
    /// Every Himawari process broadcasts changes, so this is called often: it does
    /// nothing unless where the folders belong actually changed (an open folder
    /// isn't closed by, say, a clock setting changing).
    func refresh() {
        let visible = Settings.shared.showFolders
        var zone: NSRect?
        if visible, let screen = NSScreen.main {
            // Opposite side from the widgets; clear of a top/bottom widget strip and the taskbar.
            let area = DesktopLayout.freeArea(of: screen, excluding: [.folders])
            let onRight = Settings.shared.widgetEdge == .left
            zone = NSRect(x: onRight ? area.maxX - Self.dockWidth : area.minX, y: area.minY,
                          width: Self.dockWidth, height: area.height)
        }
        if let zone, let placed, dock != nil, placed.zone == zone, placed.sources == FolderStore.sources { return }
        if zone == nil, dock == nil { DesktopLayout.setZone(.folders, nil); return }

        dock?.orderOut(nil)
        dock = nil
        closeFolder()
        timer?.invalidate()
        timer = nil
        watchers.forEach { $0.cancel() }
        watchers = []
        placed = nil
        guard let zone else {
            DesktopLayout.setZone(.folders, nil)
            return
        }

        store.reload()
        watchSources()
        // Safety net for changes the folder watcher can't see (e.g. inside subfolders).
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            onMainActor { self?.store.reload() }
        }

        let w = DesktopWindow(layer: DesktopLayer.folders, interactive: true)
        w.contentView = FirstClickHostingView(rootView: FolderDockView(store: store) { [weak self] group, frameInWindow in
            self?.openFolder(group, tileFrame: frameInWindow)
        })
        w.setFrame(zone, display: true)
        w.orderFrontRegardless()
        dock = w
        placed = (zone, FolderStore.sources)
        DesktopLayout.setZone(.folders, zone)
    }

    /// Re-scan the moment something is added, removed or renamed on the Desktop.
    /// Opening ~/Desktop can trigger macOS's permission question, which blocks the
    /// thread that asked, so the folders are opened on a background thread.
    private func watchSources() {
        let sources = FolderStore.sources
        DispatchQueue.global(qos: .utility).async {
            let fds = sources.map { open($0.path, O_EVTONLY) }.filter { $0 >= 0 }
            DispatchQueue.main.async { [weak self] in
                onMainActor {
                    guard let self else { fds.forEach { close($0) }; return }
                    for fd in fds {
                        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                               eventMask: [.write, .rename, .delete], queue: .main)
                        source.setEventHandler { [weak self] in
                            onMainActor { self?.store.reload() }
                        }
                        source.setCancelHandler { close(fd) }
                        source.resume()
                        self.watchers.append(source)
                    }
                }
            }
        }
    }

    private func openFolder(_ group: FolderGroup, tileFrame: CGRect) {
        guard let dock, let screen = dock.screen ?? NSScreen.main else { return }
        closeFolder()
        let current = store.groups.first { $0.id == group.id } ?? group

        // Where the tapped tile is, in the overlay's top-left-origin coordinates,
        // so the panel can grow out of it.
        let origin = CGPoint(x: dock.frame.minX + tileFrame.midX - screen.frame.minX,
                             y: screen.frame.maxY - (dock.frame.maxY - tileFrame.midY))

        let w = DesktopWindow(layer: DesktopLayer.overlay, interactive: true)
        w.contentView = FirstClickHostingView(rootView: FolderOverlayView(
            root: current, origin: origin, screenSize: screen.frame.size,
            onClose: { [weak self] in self?.closeFolder() }))
        w.setFrame(screen.frame, display: true)
        NSApp.activate() // so Esc reaches us
        w.makeKeyAndOrderFront(nil)
        overlay = w
    }

    private func closeFolder() {
        overlay?.orderOut(nil)
        overlay = nil
    }
}

// MARK: - Reading folders

struct FileItem: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let isFolder: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Loose files (not in any folder) are grouped by these types.
enum FileCategory: String, CaseIterable {
    case documents = "Documents", images = "Images", videos = "Videos", music = "Music"
    case code = "Code", archives = "Archives", other = "Other"

    private static let documentExtensions: Set = ["doc", "docx", "pages", "rtf", "odt", "key", "ppt", "pptx",
                                                  "numbers", "xls", "xlsx", "csv", "epub", "tex"]
    private static let codeExtensions: Set = ["ipynb", "json", "yaml", "yml", "toml", "xml", "sql", "jsonl"]

    static func of(_ url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()
        if documentExtensions.contains(ext) { return .documents }
        if codeExtensions.contains(ext) { return .code }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) { return .documents }
        return .other
    }
}

/// One iOS folder: either a real folder (id = its path) or a group of loose files by type.
struct FolderGroup: Identifiable {
    let id: String
    let title: String
    let items: [FileItem]
    var url: URL? = nil // the real folder, if this is one
}

@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var groups: [FolderGroup] = []
    /// macOS said no to reading a folder (Privacy & Security → Files and Folders).
    @Published private(set) var accessDenied = false

    /// Desktop, plus Downloads if turned on in the menu.
    static var sources: [URL] {
        let fm = FileManager.default
        var urls = [fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]]
        if Settings.shared.foldersIncludeDownloads {
            urls.append(fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        }
        return urls
    }

    /// Re-scan in the background. The first read of ~/Desktop makes macOS ask
    /// for permission, and that question blocks whichever thread asked, so it
    /// must never be the main thread (the wallpaper and clock would freeze).
    func reload() {
        let sources = Self.sources
        DispatchQueue.global(qos: .utility).async {
            let (fresh, denied) = Self.scan(sources)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let fresh = Self.inSavedOrder(fresh)
                if denied != self.accessDenied { self.accessDenied = denied }
                if fresh.map(\.items) != self.groups.map(\.items) || fresh.map(\.id) != self.groups.map(\.id) {
                    self.groups = fresh
                }
            }
        }
    }

    // MARK: Rearranging (drag a tile onto another)

    private static let orderKey = "folders.order"

    /// The order you arranged the tiles in; new folders go at the end.
    private static func inSavedOrder(_ groups: [FolderGroup]) -> [FolderGroup] {
        let order = Settings.shared.stringArray(orderKey) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return groups.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
            .map(\.element)
    }

    /// Move tile `id` to where `target` is (the others shift along, like iOS).
    func move(_ id: String, to target: String) {
        guard id != target, let from = groups.firstIndex(where: { $0.id == id }),
              let to = groups.firstIndex(where: { $0.id == target }) else { return }
        var rearranged = groups
        let tile = rearranged.remove(at: from)
        rearranged.insert(tile, at: to)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { groups = rearranged }
        Settings.shared.set(rearranged.map(\.id), for: Self.orderKey)
    }

    private nonisolated static func scan(_ sources: [URL]) -> ([FolderGroup], denied: Bool) {
        var folders: [FolderGroup] = []
        var loose: [FileCategory: [FileItem]] = [:]
        var denied = false
        for source in sources {
            guard let items = listing(of: source, denied: &denied) else { continue }
            for item in items {
                if item.isFolder {
                    var ignored = false
                    folders.append(FolderGroup(id: item.url.path, title: item.name,
                                               items: listing(of: item.url, denied: &ignored) ?? [], url: item.url))
                } else {
                    loose[FileCategory.of(item.url), default: []].append(item)
                }
            }
        }
        folders.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let looseGroups = FileCategory.allCases.compactMap { category -> FolderGroup? in
            guard let items = loose[category], !items.isEmpty else { return nil }
            return FolderGroup(id: "loose:" + category.rawValue, title: category.rawValue, items: items)
        }
        return (folders + looseGroups, denied)
    }

    /// A folder's contents, newest first. nil if it can't be read.
    nonisolated static func listing(of folder: URL, denied: inout Bool) -> [FileItem]? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isPackageKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            denied = true
            return nil
        } catch {
            return nil
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false) // apps & bundles open as files
            return FileItem(url: url, modified: values?.contentModificationDate ?? .distantPast, isFolder: isFolder)
        }
        .sorted { $0.modified > $1.modified }
    }
}

/// File icons, cached: asking the system for an icon is slowish.
@MainActor
private enum IconCache {
    private static var cache: [URL: NSImage] = [:]
    static func icon(for url: URL) -> NSImage {
        if let hit = cache[url] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[url] = icon
        return icon
    }
}

// MARK: - The folder icons on the desktop

private struct FolderDockView: View {
    @ObservedObject var store: FolderStore
    let open: (FolderGroup, CGRect) -> Void
    @State private var dragging: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.fixed(88), spacing: 16), GridItem(.fixed(88))], spacing: 20) {
                ForEach(store.groups) { group in
                    FolderTile(group: group, open: open)
                        .opacity(dragging == group.id ? 0.35 : 1)
                        // Drag a tile onto another to rearrange (iOS-style); the order is saved.
                        .onDrag {
                            dragging = group.id
                            // Dropped somewhere else entirely: un-fade the tile anyway.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if dragging == group.id { dragging = nil } }
                            return NSItemProvider(object: group.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TileDrop(target: group.id, store: store, dragging: $dragging))
                }
                if store.accessDenied {
                    AllowAccessTile()
                }
            }
            .padding(18)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.groups.map(\.id))
        }
        .frame(width: FileFolders.dockWidth)
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true } // dropped between tiles
    }
}

private struct FolderTile: View {
    let group: FolderGroup
    let open: (FolderGroup, CGRect) -> Void
    @State private var pressed = false
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 7) {
                ZStack {
                    TileBackground()
                    AeroGlass(cornerRadius: 20)
                    // A 3×3 preview of what's inside, like an iOS folder.
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(17), spacing: 4), count: 3), spacing: 4) {
                        ForEach(group.items.prefix(9)) { item in
                            Image(nsImage: IconCache.icon(for: item.url)).resizable().frame(width: 17, height: 17)
                        }
                    }
                    .frame(width: 60, height: 60, alignment: .top)
                    .padding(.top, 4)
                }
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

                Text(group.title)
                    .font(aeroFont(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .aeroText(opacity: 0.95, glow: 0.5)
            }
            .frame(width: geo.size.width)
            .scaleEffect(pressed ? 0.88 : appeared ? 1 : 0.3) // new folders pop in
            .opacity(appeared ? 1 : 0)
            .contentShape(Rectangle())
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { appeared = true } }
            .onTapGesture {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { pressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressed = false }
                    open(group, geo.frame(in: .global))
                }
            }
            .contextMenu {
                if let url = group.url {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Divider()
                    Button("Move Folder to Trash…") { Trash.confirmAndMove(url) } // the folder tile disappears by itself
                }
            }
        }
        .frame(width: 88, height: 100)
    }
}

/// Frosted glass normally; a flat tint in Battery Saver (live blur over a moving
/// wallpaper re-renders every frame).
private struct TileBackground: View {
    var body: some View {
        if PowerState.saving {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.14))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
        }
    }
}

/// While a tile is dragged over another, the tiles swap places live.
private struct TileDrop: DropDelegate {
    let target: String
    let store: FolderStore
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        onMainActor { store.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Shown when macOS hasn't let Himawari read the Desktop: opens the right Settings page.
private struct AllowAccessTile: View {
    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                AeroGlass(cornerRadius: 20)
                Image(systemName: "lock.open.fill").font(.system(size: 26)).aeroText(opacity: 0.95, glow: 0.8)
            }
            .frame(width: 72, height: 72)
            Text("Allow Access").font(aeroFont(size: 13)).aeroText(opacity: 0.95, glow: 0.5)
        }
        .frame(width: 88, height: 100)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        }
        .help("Let Himawari read your Desktop: Privacy & Security → Files and Folders → Himawari → Desktop Folder")
    }
}

// MARK: - An opened folder

private struct FolderOverlayView: View {
    let root: FolderGroup
    let origin: CGPoint   // center of the tapped tile, in this view's coordinates
    let screenSize: CGSize
    let onClose: () -> Void
    @State private var expanded = false
    @State private var path: [FolderGroup] = [] // folders opened inside this one

    private var current: FolderGroup { path.last ?? root }

    var body: some View {
        let panel = CGSize(width: min(820, screenSize.width - 200), height: min(560, screenSize.height - 220))
        let center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2 + 20)

        ZStack {
            // Blurred, slightly dimmed desktop behind the folder. Click it to close.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.15))
                .opacity(expanded ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    if !path.isEmpty {
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { _ = path.popLast() } } label: {
                            Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                                .aeroText(opacity: 1, glow: 0.7)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help("Back")
                    }
                    Text(current.title)
                        .font(aeroFont(size: 34, weight: .light))
                        .aeroText(opacity: 1, glow: 0.7)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 18) {
                        ForEach(current.items) { item in
                            FileCell(item: item) { open(item) }
                        }
                    }
                    .padding(26)
                }
                .id(current.id) // each level gets its own zoom transition
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .frame(width: panel.width, height: panel.height)
                .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.ultraThinMaterial))
                .background(AeroGlass(cornerRadius: 40))
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            }
            // The zoom: start tiny at the tile, spring out to the middle of the screen.
            .scaleEffect(expanded ? 1 : 0.1)
            .opacity(expanded ? 1 : 0)
            .position(expanded ? center : origin)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { expanded = true }
        }
        .onExitCommand(perform: dismiss) // Esc
    }

    /// Files open in their app; folders zoom open inside the panel.
    private func open(_ item: FileItem) {
        if item.isFolder {
            var denied = false
            let items = FolderStore.listing(of: item.url, denied: &denied) ?? []
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                path.append(FolderGroup(id: item.url.path, title: item.name, items: items, url: item.url))
            }
        } else {
            NSWorkspace.shared.open(item.url)
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: onClose)
    }
}

private struct FileCell: View {
    let item: FileItem
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            Text(item.name)
                .font(aeroFont(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .aeroText(opacity: 0.95, glow: 0.3)
        }
        .frame(width: 108, height: 104)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hovering ? 0.14 : 0)))
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button(item.isFolder ? "Open Folder" : "Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash…") { Trash.confirmAndMove(item.url) }.disabled(!Trash.canDelete(item.url))
        }
        .help(item.name)
    }
}
