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
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .tint(Theme.accent)
        .onAppear(perform: reload)
        .onChange(of: model.after) { reload() }
    }

    private var grid: some View {
        ScrollView {
            if visible.isEmpty {
                ContentUnavailableView(
                    "Aucune vidéo ici",
                    systemImage: "record.circle",
                    description: Text("Lance un enregistrement depuis la barre de menus, ou ⌥⇧R.")
                )
                .padding(.top, 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 22) {
                    ForEach(visible) { item in
                        VideoCard(item: item, thumbnail: model.library.folder(for: item.id).appendingPathComponent("thumbnail.jpg"))
                            .onTapGesture(count: 2) { selection = item.id }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(24)
            }
        }
        .background(Theme.canvas)
        .navigationTitle(title)
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
}

private struct VideoCard: View {
    let item: VideoItem
    let thumbnail: URL
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().aspectRatio(16 / 10, contentMode: .fill)
                } placeholder: {
                    Theme.inset
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
    }
}
