import AppKit
import HimawariKit
import SwiftUI
import UniformTypeIdentifiers

/// Himawari menu ▸ Style ▸ Customise…: pick the era and skin from live previews, choose whether
/// the look follows the genre (with your own genre rules) or the cover's colours, how much it
/// moves, which meters it shows and the name on the faceplates; make your own skin from one, or
/// import one someone shared.
@MainActor
final class StyleCustomiser {
    /// Something changed: redraw the gear and the media.
    var onChange: () -> Void = {}
    private var window: NSWindow?
    private lazy var model = CustomiseModel { [weak self] in self?.onChange() }

    /// The window drawn offscreen to a PNG (`--render-customise <file>`), for checking its layout.
    func snapshot(to url: URL) {
        show()
        guard let view = window?.contentView else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(8)) // the previews draw one by one
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The skins folder changed: redraw the previews (the window stays as it is otherwise).
    func skinsChanged() {
        guard window?.isVisible == true else { return }
        model.skinsChanged()
    }

    func show() {
        model.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Customise Style"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CustomiseView(model: model))
            w.minSize = NSSize(width: 820, height: 600)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                onMainActor { self?.model.flush() } // typing not yet applied: apply it
            }
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class CustomiseModel: ObservableObject {
    @Published var chosen: String = Styles.shared.chosen.id
    @Published var options = Styles.shared.options
    @Published private(set) var skins: [GearEra: [Skin]] = [:]
    @Published private(set) var problems: [String] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var preview: NSImage?
    @Published var notice: String?
    private let changed: () -> Void
    private var pendingPreview: DispatchWorkItem?
    private var pendingApply: DispatchWorkItem?
    private var renderingThumbnails = false

    init(changed: @escaping () -> Void) { self.changed = changed }

    func reload() {
        chosen = Styles.shared.chosen.id
        options = Styles.shared.options
        let library = Styles.shared.library
        skins = Dictionary(uniqueKeysWithValues: GearEra.allCases.map { ($0, library.skins(of: $0)) })
        problems = library.problems
        thumbnails = thumbnails.filter { id, _ in library.skin(id: id) != nil }
        renderThumbnails()
        refreshPreview()
    }

    var allSkins: [Skin] { GearEra.allCases.flatMap { skins[$0] ?? [] } }

    func choose(_ id: String) {
        chosen = id
        Styles.shared.select(id)
        apply()
    }

    /// Saves the options and shows them, on the desktop and in the preview.
    func apply() {
        options.brand = StyleOptions.cleanBrand(options.brand)
        Styles.shared.options = options
        changed()
        refreshPreview()
    }

    /// Typing (a name, a genre): applied a moment after you stop, and when the window closes.
    func applySoon() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in onMainActor { self?.apply() } }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func flush() {
        guard let pending = pendingApply, !pending.isCancelled else { return }
        pending.cancel()
        apply()
    }

    func resetRules() {
        options.rules = GenreRule.defaults
        apply()
    }

    // MARK: Pictures

    /// The big preview: the chosen style with these options (the genre and the cover follow the
    /// song, so the preview shows the style itself).
    private func refreshPreview() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in
            onMainActor {
                guard let self, let skin = Styles.shared.library.skin(id: self.chosen) else { return }
                var dressed = skin
                if let brand = StyleOptions.cleanBrand(self.options.brand) { dressed.brand = brand }
                if let cg = StylePreview.image(dressed, meters: self.options.meters, animation: self.options.animation, scale: 1) {
                    self.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// One small picture per skin, drawn one at a time so the window stays responsive.
    private func renderThumbnails() {
        guard !renderingThumbnails else { return } // one at a time, however often the skins reload
        renderingThumbnails = true
        DispatchQueue.main.async { [weak self] in
            onMainActor {
                guard let self else { return }
                // Chosen now, not when scheduled: the skins may have been reloaded meanwhile.
                guard let next = self.allSkins.first(where: { self.thumbnails[$0.id] == nil }) else {
                    self.renderingThumbnails = false
                    return
                }
                if let cg = StylePreview.image(next, scale: 0.35) {
                    self.thumbnails[next.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                self.renderingThumbnails = false
                self.renderThumbnails()
            }
        }
    }

    // MARK: Your own skins

    func makeCopy() {
        guard let skin = Styles.shared.library.skin(id: chosen) else { return }
        do {
            let url = try Styles.shared.makeCopy(of: skin)
            reload()
            choose(url.deletingPathExtension().lastPathComponent)
            NSWorkspace.shared.open(url) // in your text editor: change the colours, save, then Reload
            notice = "Saved \(url.lastPathComponent) in the Skins folder. Change it, save, then press Reload."
        } catch {
            notice = "Couldn't save a copy: \(error.localizedDescription)"
        }
    }

    func makeDesign() {
        guard let skin = Styles.shared.library.skin(id: chosen) else { return }
        do {
            let made = try Styles.shared.makeDesign(from: skin)
            reload()
            choose(made.skin)
            NSWorkspace.shared.open(made.design)
            notice = "Saved \(made.design.lastPathComponent) in the Designs folder, and a skin wearing it. Move the blocks about and save: the desktop follows."
        } catch {
            notice = "Couldn't save the design: \(error.localizedDescription)"
        }
    }

    func importSkin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose skin files (.json) to add to Himawari."
        guard panel.runModal() == .OK else { return }
        var added: [String] = [], failed: [String] = []
        for url in panel.urls {
            do { added.append(try Styles.shared.importSkin(from: url).name) } catch { failed.append("\(url.lastPathComponent): \(error)") }
        }
        reload()
        notice = ([added.isEmpty ? nil : "Added " + added.joined(separator: ", ") + "."] + failed.map { Optional($0) })
            .compactMap { $0 }.joined(separator: "  ")
    }

    /// Someone saved a skin file: draw the previews again from the new files.
    func skinsChanged() {
        thumbnails = [:]
        reload()
    }

    func reloadSkins() {
        Styles.shared.reload()
        thumbnails = [:]
        reload()
        changed()
    }
}

// MARK: - The window

private struct CustomiseView: View {
    @ObservedObject var model: CustomiseModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                preview
                styles
            }
            .frame(minWidth: 520)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    follow
                    optionsSection
                    yourOwn
                }
                .padding(.trailing, 6)
            }
            .frame(width: 300)
        }
        .padding(20)
    }

    private var preview: some View {
        Group {
            if let image = model.preview {
                Image(nsImage: image).resizable().aspectRatio(1470 / 956, contentMode: .fit)
            } else {
                Rectangle().fill(Color.black.opacity(0.3)).aspectRatio(1470 / 956, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))
    }

    private var styles: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(GearEra.allCases, id: \.self) { era in
                    if let skins = model.skins[era], !skins.isEmpty {
                        Text(era.title).font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(skins, id: \.id) { skin in tile(skin) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func tile(_ skin: Skin) -> some View {
        let design = skin.design.flatMap { Styles.shared.library.design(id: $0) }
        let selected = skin.id == model.chosen
        return Button { model.choose(skin.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let image = model.thumbnails[skin.id] {
                        Image(nsImage: image).resizable().aspectRatio(1470 / 956, contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.black.opacity(0.25)).aspectRatio(1470 / 956, contentMode: .fit)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
                Text(design.map { "\(skin.name) · \($0.name)" } ?? skin.name).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(Skin.builtIn.contains { $0.id == skin.id } ? skin.name : "\(skin.name) (your skin: \(skin.id).json)")
    }

    private var follow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The look").font(.headline)
            Picker("", selection: $model.options.mode) {
                Text("Always this style").tag(StyleOptions.Mode.pinned)
                Text("Follow the song's genre").tag(StyleOptions.Mode.genre)
                Text("Take the cover's colours").tag(StyleOptions.Mode.coverColours)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: model.options.mode) { _, _ in model.apply() }
            switch model.options.mode {
            case .genre: rules
            case .coverColours:
                Text("The chosen style, its displays and lamps lit in the colours of each song's cover.")
                    .font(.caption).foregroundStyle(.secondary)
            case .pinned:
                EmptyView()
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Genres to styles (the first match wins; songs with no match get the chosen style). The genre comes from Apple's catalog.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.options.rules.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("genre", text: $model.options.rules[i].genre)
                        .frame(width: 100)
                        .onSubmit { model.apply() }
                        .onChange(of: model.options.rules[i].genre) { _, _ in model.applySoon() }
                    Picker("", selection: $model.options.rules[i].skin) {
                        ForEach(model.allSkins, id: \.id) { skin in Text("\(skin.era.title): \(skin.name)").tag(skin.id) }
                    }
                    .labelsHidden()
                    .onChange(of: model.options.rules[i].skin) { _, _ in model.apply() }
                    Button { model.options.rules.remove(at: i); model.apply() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Rule") { model.options.rules.append(GenreRule(genre: "", skin: model.chosen)) }
                Button("Defaults") { model.resetRules() }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options").font(.headline)
            HStack {
                Text("Animation").frame(width: 74, alignment: .leading)
                // (Not $model.options.animation: a Binding has an animation(_:) of its own.)
                Picker("", selection: Binding(get: { model.options.animation }, set: { model.options.animation = $0 })) {
                    Text("Full").tag(StyleOptions.Animation.full)
                    Text("Reduced").tag(StyleOptions.Animation.reduced)
                    Text("Still").tag(StyleOptions.Animation.still)
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: model.options.animation) { _, _ in model.apply() }
            }
            HStack {
                Text("Meters").frame(width: 74, alignment: .leading)
                Picker("", selection: $model.options.meters) {
                    Text("Era's").tag(StyleOptions.Meters.era)
                    Text("Needles").tag(StyleOptions.Meters.needles)
                    Text("LEDs").tag(StyleOptions.Meters.leds)
                    Text("Spectrum").tag(StyleOptions.Meters.spectrum)
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: model.options.meters) { _, _ in model.apply() }
            }
            HStack {
                Text("Name").frame(width: 74, alignment: .leading)
                TextField("HIMAWARI", text: Binding(get: { model.options.brand ?? "" }, set: { model.options.brand = $0; model.applySoon() }))
                    .onSubmit { model.apply() }
            }
            Text("Still: nothing moves by itself; the meters still follow the music. The name replaces the brand on the faceplates.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var yourOwn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your own skins").font(.headline)
            Text("A skin is a small JSON file of colours, materials, fonts and a few sizes. Start from the one selected, or add one someone shared. Files reload as you save them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Make My Own…") { model.makeCopy() }
                Button("Import…") { model.importSkin() }
            }
            Text("Your own era: a design file lays out the panels as blocks (display, buttons, wheel, meters, knobs, grille…) and picks what plays in the middle.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Make My Own Era…") { model.makeDesign() }
                Button("Open Designs Folder") { Styles.shared.reload(); NSWorkspace.shared.open(SkinLibrary.designsFolder) }
            }
            HStack {
                Button("Open Skins Folder") { Styles.shared.reload(); NSWorkspace.shared.open(SkinLibrary.folder) }
                Button("Reload") { model.reloadSkins() }
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            ForEach(model.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
