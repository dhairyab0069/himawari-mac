import AppKit
import HimawariKit
import SwiftUI

/// The deck's disc changer: what's next in the playing playlist, and your playlists as discs to
/// flip through and play. Opened with the deck's ⏏ button or ⌃⌥⌘P; Esc or a click outside closes it.
///
/// What it can offer depends on the player (see PlaylistLibrary): Apple Music, everything;
/// Spotify, the playlists you've pinned by their link; other players, a way to open them.
@MainActor
final class PlaylistChanger: ObservableObject {
    let library = PlaylistLibrary()
    /// The player being followed and what it allows (kept current by AppDelegate).
    @Published var player: PlayerKind?
    @Published var capabilities: PlayerCapabilities = .all
    @Published private(set) var pinned: [String]
    @Published private(set) var spotifyLinks: [Playlist]
    @Published var notice: String?
    var openPlayer: () -> Void = {}

    private var panel: ChangerPanel?
    private var monitors: [Any] = []
    private let settings = Settings.shared

    init() {
        pinned = Settings.shared.pinnedPlaylists
        spotifyLinks = Settings.shared.spotifyPlaylists.map {
            Playlist(source: .spotify(uri: $0.uri), name: $0.name, count: nil)
        }
        library.loadSavedCovers(for: spotifyLinks)
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(near screen: NSScreen? = NSScreen.main) {
        isOpen ? close() : open(on: screen)
    }

    func open(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        notice = nil
        if player == .appleMusic || player == nil { library.reloadAppleMusic() }
        let panel = self.panel ?? ChangerPanel(content: ChangerView(changer: self))
        self.panel = panel
        let size = NSSize(width: 620, height: 470)
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.onEscape = { [weak self] in self?.close() }
        panel.makeKeyAndOrderFront(nil)
        // A click anywhere outside closes it (other apps' windows included).
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            onMainActor { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // Not for clicks on the gear's controls: the ⏏ button toggles the changer itself
            // (closing here first would make it open again).
            let gear = event.window?.identifier == GearControls.catcherID
            if event.window !== self?.panel, !gear { onMainActor { self?.close() } }
            return event
        } as Any)
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
    }

    // MARK: What's shown

    /// Apple Music's playlists (pinned first) when it's the player, plus pinned Spotify links.
    var shelves: [(title: String, items: [Playlist])] {
        let am = (player == .appleMusic || player == nil) ? library.playlists : []
        let all = am + spotifyLinks
        let pinnedItems = pinned.compactMap { id in all.first { $0.id == id } }
        let rest = all.filter { !pinned.contains($0.id) }
        var shelves: [(String, [Playlist])] = []
        if !pinnedItems.isEmpty { shelves.append(("PINNED", pinnedItems)) }
        let restAM = rest.filter { if case .appleMusic = $0.source { true } else { false } }
        let restSpotify = rest.filter { if case .spotify = $0.source { true } else { false } }
        if !restAM.isEmpty { shelves.append(("APPLE MUSIC PLAYLISTS", restAM)) }
        if !restSpotify.isEmpty { shelves.append(("SPOTIFY PLAYLISTS", restSpotify)) }
        return shelves
    }

    var canPlayPlaylists: Bool { capabilities.contains(.playlists) || player == nil }

    // MARK: Actions

    func play(_ playlist: Playlist) {
        switch playlist.source {
        case .appleMusic:
            guard player == .appleMusic || player == nil else { notice = "Switch to Apple Music to play this."; return }
        case .spotify:
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else {
                notice = "Open Spotify first, then pick the playlist."; return
            }
        }
        library.play(playlist)
        close()
    }

    func togglePin(_ playlist: Playlist) {
        if let i = pinned.firstIndex(of: playlist.id) { pinned.remove(at: i) } else { pinned.insert(playlist.id, at: 0) }
        settings.pinnedPlaylists = pinned
    }

    func remove(_ playlist: Playlist) {
        spotifyLinks.removeAll { $0.id == playlist.id }
        pinned.removeAll { $0 == playlist.id }
        settings.pinnedPlaylists = pinned
        saveSpotifyLinks()
    }

    private func saveSpotifyLinks() {
        settings.spotifyPlaylists = spotifyLinks.compactMap {
            if case .spotify(let uri) = $0.source { (uri, $0.name) } else { nil }
        }
    }

    /// Adds the Spotify playlist whose link is on the clipboard (Share ▸ Copy Link to Playlist).
    func addSpotifyLinkFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), PlaylistLibrary.spotifyURI(fromLink: text) != nil else {
            notice = "Copy a Spotify playlist's link first: Share ▸ Copy Link to Playlist."
            return
        }
        notice = "Adding…"
        Task { [weak self] in
            guard let self else { return }
            guard let (playlist, cover) = await self.library.spotifyPlaylist(fromLink: text) else {
                self.notice = "Couldn't read that playlist. Check it's public and you're online." // not "Adding…" forever
                return
            }
            if !self.spotifyLinks.contains(where: { $0.id == playlist.id }) { self.spotifyLinks.append(playlist) }
            self.library.setCover(cover, for: playlist)
            self.saveSpotifyLinks()
            self.notice = "Added “\(playlist.name)”."
        }
    }
}

/// A borderless panel that can take keys (Esc) without bringing Himawari forward.
@MainActor
private final class ChangerPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(content: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        identifier = NSUserInterfaceItemIdentifier("himawari.disc-changer")
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - The look: the same brushed metal and cyan fluorescent display as the deck

private let vfd = Color(red: 0.45, green: 0.97, blue: 1)
private let amber = Color(red: 1, green: 0.72, blue: 0.3)

private struct ChangerView: View {
    @ObservedObject var changer: PlaylistChanger
    @ObservedObject var library: PlaylistLibrary

    init(changer: PlaylistChanger) {
        self.changer = changer
        self.library = changer.library
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let position = library.position, changer.capabilities.contains(.upNext) {
                upNext(position)
            }
            if changer.canPlayPlaylists || !changer.spotifyLinks.isEmpty {
                shelves
            } else {
                Text("\(changer.player?.title ?? "This player") doesn't let Himawari read or play its playlists.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(18)
        .frame(width: 620, height: 470)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black, lineWidth: 1))
                .shadow(radius: 20)
        )
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HIMAWARI").font(.system(size: 13, weight: .bold)).tracking(3)
                Text("DISC CHANGER  DC-27").font(.system(size: 8, weight: .medium)).tracking(2).opacity(0.55)
            }
            Spacer()
            if library.loading { ProgressView().controlSize(.small) }
            Button { changer.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Close (Esc)")
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private func upNext(_ position: PlaylistPosition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(position.label.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(vfd)
            if position.upNext.isEmpty {
                Text("SHUFFLING: WHAT'S NEXT IS UP TO MUSIC").font(.system(size: 10, design: .monospaced)).foregroundStyle(vfd.opacity(0.5))
            }
            ForEach(position.upNext) { item in
                Button { library.play(upNext: item) } label: {
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", item.index)).foregroundStyle(vfd.opacity(0.5))
                        Text(item.title.uppercased()).foregroundStyle(vfd).lineLimit(1)
                        Text(item.artist.uppercased()).foregroundStyle(vfd.opacity(0.55)).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Skip to this song")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.02, green: 0.08, blue: 0.1)))
    }

    private var shelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(changer.shelves, id: \.title) { shelf in
                    Text(shelf.title).font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.5))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 12), count: 5), alignment: .leading, spacing: 12) {
                        ForEach(shelf.items) { playlist in disc(playlist) }
                    }
                }
                if changer.shelves.isEmpty {
                    Text(library.loading ? "Reading your playlists…" : "No playlists yet.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func disc(_ playlist: Playlist) -> some View {
        let isPinned = changer.pinned.contains(playlist.id)
        return Button { changer.play(playlist) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let cover = library.covers[playlist.id] {
                            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(Image(systemName: "opticaldisc").font(.system(size: 28)).foregroundStyle(.white.opacity(0.35)))
                        }
                    }
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
                    if isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(amber).padding(5)
                    }
                }
                Text(playlist.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(.white.opacity(0.9))
                Text(subtitle(playlist)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 104, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin to the Top") { changer.togglePin(playlist) }
            if case .spotify = playlist.source { Button("Remove") { changer.remove(playlist) } }
        }
        .help("Play \(playlist.name)")
    }

    private func subtitle(_ p: Playlist) -> String {
        switch p.source {
        case .appleMusic: p.count.map { "\($0) songs" } ?? "Apple Music"
        case .spotify: "Spotify"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open \(changer.player?.title ?? "Apple Music")") { changer.openPlayer(); changer.close() }
            if changer.player == .spotify || !changer.spotifyLinks.isEmpty {
                Button("Add Spotify Playlist from Clipboard") { changer.addSpotifyLinkFromClipboard() }
                    .help("In Spotify: Share ▸ Copy Link to Playlist, then click here")
            }
            Spacer()
            if let notice = changer.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(amber).lineLimit(1)
            }
        }
        .controlSize(.small)
    }
}
