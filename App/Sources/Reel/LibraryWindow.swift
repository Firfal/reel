import AVKit
import ReelKit
import SwiftUI

@MainActor
final class LibraryWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bibliothèque"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.center()
        window.setFrameAutosaveName("Library")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            // Back to a menu bar app once the last window closes.
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
        }
        return window
    }
}

enum LibrarySection: Hashable {
    case all, shared, archived
    case folder(String)
}

struct LibraryView: View {
    let model: AppModel
    @State private var items: [VideoItem] = []
    @State private var section: LibrarySection = .all
    @State private var selection: VideoItem.ID?
    @State private var search = ""
    @State private var importing = false
    @State private var importFailures: [String] = []

    private var folders: [String] { Array(Set(items.compactMap(\.folder))).sorted() }

    private var visible: [VideoItem] {
        items.filter { item in
            let inSection = switch section {
            case .all: !item.isArchived
            case .shared: item.shareURL != nil && !item.isArchived
            case .archived: item.isArchived
            case .folder(let name): item.folder == name && !item.isArchived
            }
            return inSection && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    Label("Bibliothèque", systemImage: "play.rectangle.on.rectangle").tag(LibrarySection.all)
                    Label("Partagées", systemImage: "link").tag(LibrarySection.shared)
                }
                if !folders.isEmpty {
                    Section("Dossiers") {
                        ForEach(folders, id: \.self) { Label($0, systemImage: "folder").tag(LibrarySection.folder($0)) }
                    }
                }
                Section {
                    Label("Archives", systemImage: "archivebox").tag(LibrarySection.archived)
                }
            }
            .scrollContentBackground(.hidden)
            .background(alignment: .top) { Theme.sidebarTint.ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if let id = selection, let item = items.first(where: { $0.id == id }) {
                EditorView(item: item, library: model.library, onClose: { selection = nil; reload() }, onChange: reload)
            } else {
                grid
            }
        }
        .tint(Theme.accent)
        .onAppear {
            reload()
            if let id = DemoMode.openItemID { selection = id }
        }
        .onChange(of: model.after) { reload() }
    }

    private var grid: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: search.isEmpty ? "record.circle" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty ? "Lance un enregistrement depuis la barre de menus, ou ⌥⇧R." : "Aucun titre ne contient « \(search) ».")
                } actions: {
                    if search.isEmpty && section == .all {
                        Button("Importer une vidéo…") { Task { await importVideos() } }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], spacing: 24) {
                        ForEach(visible) { item in
                            Button { selection = item.id } label: {
                                VideoCard(item: item, folder: model.library.folder(for: item.id))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(Theme.Spacing.page)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .alert("Import impossible", isPresented: Binding(get: { !importFailures.isEmpty }, set: { if !$0 { importFailures = [] } })) {
            Button("OK") {}
        } message: {
            Text("Ces fichiers n'ont pas pu être lus comme des vidéos : \(importFailures.joined(separator: ", ")).")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await importVideos() }
                } label: {
                    if importing { ProgressView().controlSize(.small) } else { Label("Importer une vidéo", systemImage: "square.and.arrow.down") }
                }
                .help("Importer une vidéo existante")
                .disabled(importing)
            }
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "Aucun résultat" }
        return switch section {
        case .all: "Aucune vidéo pour l'instant"
        case .shared: "Aucune vidéo partagée"
        case .archived: "Rien dans les archives"
        case .folder: "Ce dossier est vide"
        }
    }

    private var title: String {
        switch section {
        case .all: "Bibliothèque"
        case .shared: "Partagées"
        case .archived: "Archives"
        case .folder(let name): name
        }
    }

    @ViewBuilder private func contextMenu(for item: VideoItem) -> some View {
        Button("Ouvrir") { selection = item.id }
        if let url = item.shareURL {
            Button("Copier le lien") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Ouvrir dans le navigateur") { NSWorkspace.shared.open(url) }
        }
        Button("Afficher dans le Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.library.videoURL(for: item.id)])
        }
        Menu("Déplacer vers") {
            ForEach(folders, id: \.self) { folder in Button(folder) { update(item) { $0.folder = folder } } }
            Button("Nouveau dossier…") { newFolder(for: item) }
            if item.folder != nil { Button("Aucun dossier") { update(item) { $0.folder = nil } } }
        }
        Divider()
        Button(item.isArchived ? "Désarchiver" : "Archiver") { update(item) { $0.isArchived.toggle() } }
    }

    private func newFolder(for item: VideoItem) {
        let alert = NSAlert()
        alert.messageText = "Nouveau dossier"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Nom du dossier"
        alert.accessoryView = field
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        update(item) { $0.folder = field.stringValue }
    }

    private func update(_ item: VideoItem, _ change: (inout VideoItem) -> Void) {
        var copy = item
        change(&copy)
        try? model.library.save(copy)
        reload()
    }

    private func reload() { items = model.library.items() }

    private func importVideos() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choisis les vidéos à ajouter à ta bibliothèque."
        guard panel.runModal() == .OK else { return }
        importing = true
        var failures: [String] = []
        for url in panel.urls {
            do { _ = try await model.importVideo(from: url) } catch { failures.append(url.lastPathComponent) }
        }
        importing = false
        importFailures = failures
        reload()
    }
}

private struct VideoCard: View {
    let item: VideoItem
    let folder: URL
    @State private var hovering = false
    /// Decoded once, at card size: AsyncImage would decode the full JPEG again after every hover.
    @State private var image: NSImage?
    @State private var hasPreview = false

    private var thumbnail: URL { folder.appendingPathComponent("thumbnail.jpg") }
    private var preview: URL { folder.appendingPathComponent("preview.gif") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Theme.inset
                    .overlay {
                        if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .overlay {
                        // The GIF plays over the still, so leaving the card shows the still at once.
                        if hovering, hasPreview { AnimatedImage(url: preview) }
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                Text(ControlBar.format(item.duration))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(hovering ? Theme.accent : Theme.line, lineWidth: hovering ? 2 : 1)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    if item.shareURL != nil { Image(systemName: "link") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.standard, value: hovering)
        .task(id: item.id) {
            let (url, previewURL) = (thumbnail, preview)
            let loaded = await Task.detached(priority: .utility) { () -> (CGImage?, Bool) in
                (Self.downsample(url, maxPixels: 640), FileManager.default.fileExists(atPath: previewURL.path))
            }.value
            image = loaded.0.map { NSImage(cgImage: $0, size: .zero) }
            hasPreview = loaded.1
        }
    }

    nonisolated private static func downsample(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}

/// Plays an animated GIF; SwiftUI's Image shows only its first frame.
private struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(contentsOf: url)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
