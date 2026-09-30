import AppKit
import HimawariKit
import SwiftUI

// The Start menu's more modern features, in XP clothes:
//   • pinned apps you choose (right-click ▸ Pin / Unpin), saved across restarts
//   • frequently used apps, learned from what you actually switch to
//   • search as you type: programs instantly, files via Spotlight
//   • My Recent Documents ▸ (files you opened lately, via Spotlight)
//   • XP-style right-click menus

// MARK: - Pinned & frequently used

@MainActor
enum StartMenuData {
    private static let pinnedKey = "start.pinned"
    private static let usageKey = "start.usage"

    /// Your pinned apps, or a sensible default set until you pin/unpin something.
    static var pinned: [URL] {
        if let paths = Settings.shared.stringArray(pinnedKey) {
            return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return StartItems.defaultPinned
    }

    static func isPinned(_ url: URL) -> Bool { pinned.contains(url) }

    static func pin(_ url: URL) {
        guard !isPinned(url) else { return }
        Settings.shared.set((pinned + [url]).map(\.path), for: pinnedKey)
    }

    static func unpin(_ url: URL) {
        Settings.shared.set(pinned.filter { $0 != url }.map(\.path), for: pinnedKey)
    }

    /// Top apps by how often you switch to them, excluding pinned ones.
    static func frequent(limit: Int = 5) -> [URL] {
        let pinnedPaths = Set(pinned.map(\.path))
        return Settings.shared.counts(usageKey)
            .filter { !pinnedPaths.contains($0.key) && isUserApp(URL(fileURLWithPath: $0.key))
                && FileManager.default.fileExists(atPath: $0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.key) }
    }

    /// Where real, user-facing apps live (not macOS's hidden helpers like the permission prompt).
    static func isUserApp(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.pathExtension == "app"
            && ["/Applications/", "/System/Applications/", home + "/Applications/"].contains { url.path.hasPrefix($0) }
    }

    static func recordUse(_ url: URL) {
        guard isUserApp(url) else { return }
        var counts = Settings.shared.counts(usageKey)
        counts[url.path, default: 0] += 1
        Settings.shared.set(counts, for: usageKey)
    }

    static func forget(_ url: URL) {
        var counts = Settings.shared.counts(usageKey)
        counts[url.path] = nil
        Settings.shared.set(counts, for: usageKey)
    }

    /// Filled each time the Start menu opens (Spotlight answers asynchronously).
    static var recentDocuments: [URL] = []

    static func refreshRecentDocuments() {
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        Spotlight.run(NSPredicate(format: "kMDItemLastUsedDate >= %@ AND NOT (kMDItemContentTypeTree CONTAINS %@) AND NOT (kMDItemContentTypeTree CONTAINS %@)",
                                  monthAgo as NSDate, "com.apple.application-bundle", "public.folder"),
                      limit: 15) { recentDocuments = $0 }
    }
}

// MARK: - Spotlight

@MainActor
enum Spotlight {
    private static var running: [NSMetadataQuery] = []

    /// Search your home folder; results come back newest-used first.
    /// Holds a query and its observer; only ever touched on the main thread.
    private final class Pending: @unchecked Sendable {
        let query = NSMetadataQuery()
        var token: NSObjectProtocol?
    }

    static func run(_ predicate: NSPredicate, limit: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        let pending = Pending()
        let query = pending.query
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        pending.token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                               queue: .main) { _ in
            onMainActor {
                let query = pending.query
                query.stop()
                let urls = (0..<min(query.resultCount, limit)).compactMap { i -> URL? in
                    (query.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey)
                        .flatMap { $0 as? String }.map { URL(fileURLWithPath: $0) }
                }
                if let token = pending.token { NotificationCenter.default.removeObserver(token) }
                running.removeAll { $0 === query }
                completion(urls)
            }
        }
        running.append(query)
        query.start()
    }
}

/// Search as you type: programs match instantly, files arrive from Spotlight a moment later.
@MainActor
final class StartSearch: ObservableObject {
    @Published private(set) var programs: [URL] = []
    @Published private(set) var files: [URL] = []
    private var generation = 0

    var first: URL? { programs.first ?? files.first }

    func update(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        generation += 1
        guard !text.isEmpty else { programs = []; files = []; return }

        let usage = Settings.shared.counts("start.usage")
        programs = StartItems.appURLs()
            .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(text) }
            .sorted { a, b in
                let an = a.deletingPathExtension().lastPathComponent, bn = b.deletingPathExtension().lastPathComponent
                let ap = an.lowercased().hasPrefix(text.lowercased()), bp = bn.lowercased().hasPrefix(text.lowercased())
                if ap != bp { return ap }                                       // "Fi" → Firefox before "Wi-Fi…"
                return (usage[a.path] ?? 0) > (usage[b.path] ?? 0)              // then the ones you use most
            }
            .prefix(6).map { $0 }

        let mine = generation
        Spotlight.run(NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@ AND NOT (kMDItemContentTypeTree CONTAINS %@)",
                                  text, "com.apple.application-bundle"),
                      limit: 6) { [weak self] urls in
            guard let self, mine == self.generation else { return } // a newer keystroke won
            self.files = urls
        }
    }
}

// MARK: - XP right-click menus

/// Catches right-clicks (and only right-clicks: everything else passes through
/// to the view underneath) and reports where they happened, in screen coordinates.
struct RightClickCatcher: NSViewRepresentable {
    let action: (NSPoint) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (NSPoint) -> Void
        init(action: @escaping (NSPoint) -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action(NSEvent.mouseLocation) }
    }
}

extension View {
    /// An XP right-click menu (instead of the dark macOS one).
    func xpContextMenu(_ items: @escaping @MainActor () -> [XPMenuItem]) -> some View {
        overlay(RightClickCatcher { point in
            onMainActor {
                XPFlyouts.shared.open(items(), beside: NSRect(origin: point, size: .zero), depth: 0, width: 210)
            }
        })
    }
}

@MainActor
enum AppMenu {
    /// Right-click menu for an app anywhere in the Start menu.
    static func items(for url: URL, frequent: Bool = false) -> [XPMenuItem] {
        var items = [XPMenuItem(title: "Open", symbol: "arrow.up.forward.app") { Apps.open(url) }, .separator]
        if StartMenuData.isPinned(url) {
            items.append(XPMenuItem(title: "Unpin from Start menu", symbol: "pin.slash") { StartMenuData.unpin(url) })
        } else {
            items.append(XPMenuItem(title: "Pin to Start menu", symbol: "pin") { StartMenuData.pin(url) })
        }
        if frequent {
            items.append(XPMenuItem(title: "Remove from this list", symbol: "minus.circle") { StartMenuData.forget(url) })
        }
        items += [.separator, XPMenuItem(title: "Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }, .separator, XPMenuItem(title: "Move to Trash…", symbol: "trash", enabled: Trash.canDelete(url)) {
            Trash.confirmAndMove(url) {
                StartMenuData.unpin(url)
                StartMenuData.forget(url)
            }
        }]
        return items
    }

    /// Right-click menu for a file (search results, recent documents).
    static func items(forFile url: URL) -> [XPMenuItem] {
        [XPMenuItem(title: "Open", symbol: "doc") { NSWorkspace.shared.open(url) },
         XPMenuItem(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
         .separator,
         XPMenuItem(title: "Move to Trash…", symbol: "trash", enabled: Trash.canDelete(url)) {
             Trash.confirmAndMove(url) { StartMenuData.recentDocuments.removeAll { $0 == url } }
         }]
    }
}
