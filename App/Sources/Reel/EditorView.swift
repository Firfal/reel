import AVKit
import ReelKit
import SwiftUI

/// Editing one video: preview, a timeline of video frames (from « Sable »), and the transcript where
/// striking a word cuts it. Edits are non-destructive and saved next to the video as edit.json.
struct EditorView: View {
    let item: VideoItem
    let library: Library
    let onClose: () -> Void
    let onChange: () -> Void

    @State private var player = AVPlayer()
    @State private var edit = Edit()
    @State private var transcript: Transcript?
    @State private var title = ""
    /// The playhead, read only by the views that show it: the rest of the editor doesn't redraw 20 times a second.
    @State private var clock = PlaybackClock()
    private var currentTime: Double { clock.time }
    @State private var suggestions = CleanupSuggestions()
    @State private var sharing: AfterRecording = .idle
    @State private var shareURL: URL?
    @State private var timeObserver: Any?
    @State private var levels: AudioLevels?
    @State private var details = SharedDetails()
    @State private var styling = Styling()
    @State private var videoAspect: CGFloat = 16 / 9
    @State private var tab = InspectorTab.demo ?? .transcript
    @State private var aiWorking = false

    enum InspectorTab: String, CaseIterable {
        case transcript = "Transcription", ai = "IA", styling = "Habillage", share = "Partage", agent = "Agent"

        var symbol: String {
            switch self {
            case .transcript: "text.quote"
            case .ai: "sparkles"
            case .styling: "paintbrush"
            case .share: "link"
            case .agent: "cursorarrow.rays"
            }
        }

        /// `--tab ai|styling|share|agent`, for screenshots during development.
        static var demo: InspectorTab? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--tab"), arguments.indices.contains(index + 1) else { return nil }
            return ["transcript": .transcript, "ai": .ai, "styling": .styling, "share": .share, "agent": .agent][arguments[index + 1]]
        }
    }

    private var agentFolder: URL { folder.appendingPathComponent("agent") }
    private var hasAgentPlan: Bool { FileManager.default.fileExists(atPath: agentFolder.appendingPathComponent("plan.md").path) }

    private var folder: URL { library.folder(for: item.id) }
    private var editURL: URL { folder.appendingPathComponent("edit.json") }
    private var detailsURL: URL { folder.appendingPathComponent("insights.json") }
    private var stylingURL: URL { folder.appendingPathComponent("styling.json") }

    @State private var showsInspector = true
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            PlayerView(player: player)
                .overlay { OverlayCanvas(styling: $styling, clock: clock, videoAspect: videoAspect) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .frame(minHeight: 240)
                .padding(.horizontal, Self.gutter)
            FilmstripTimeline(
                videoURL: library.videoURL(for: item.id),
                duration: item.duration,
                edit: $edit,
                clock: clock,
                onSeek: seek
            )
            .frame(height: 92)
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, Theme.Spacing.section)
        }
        .frame(minWidth: 480)
        .background(Theme.canvas)
        .navigationTitle("")
        .toolbar { toolbar }
        .inspector(isPresented: $showsInspector) {
            inspector
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .onAppear(perform: load)
        // macOS focuses the first text field of a new window; the title stays quiet until clicked.
        .task { titleFocused = false }
        .onDisappear(perform: unload)
        .onChange(of: edit) {
            save()
            isSettled = true
        }
        .onChange(of: details) { try? JSONEncoder().encode(details).write(to: detailsURL) }
        .onChange(of: styling) { try? JSONEncoder().encode(styling).write(to: stylingURL) }
        .task {
            levels = try? await AudioLevels.measure(library.videoURL(for: item.id))
            computeSuggestions()
        }
    }

    /// Player, timeline and title share one edge.
    private static let gutter = Theme.Spacing.gutter

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onClose) { Label("Bibliothèque", systemImage: "chevron.left") }
                .help("Retour à la bibliothèque")
                .keyboardShortcut("[", modifiers: .command)
        }
        ToolbarItem {
            ControlGroup {
                ForEach(Overlay.Kind.allCases, id: \.self) { kind in
                    Button { addOverlay(kind) } label: { Label(Self.overlayName(kind), systemImage: StylingPanel.symbol(kind)) }
                        .help("Ajouter \(Self.overlayName(kind).lowercased())")
                }
            } label: {
                Label("Annoter", systemImage: "textformat")
            }
        }
        ToolbarItem {
            Button { Task { await setThumbnail() } } label: { Label("Miniature", systemImage: "photo") }
                .help("Utiliser l'image affichée comme miniature")
        }
        ToolbarItem {
            Button { Task { await share() } } label: {
                Label(shareURL == nil ? "Partager" : "Mettre à jour le lien", systemImage: "square.and.arrow.up")
            }
            .help(shareURL == nil ? "Envoyer la vidéo et copier son lien" : "Renvoyer la vidéo montée : un nouveau lien remplace l'ancien")
            .disabled(isSharing)
        }
        ToolbarItem {
            Button { showsInspector.toggle() } label: { Label("Inspecteur", systemImage: "sidebar.right") }
                .help(showsInspector ? "Masquer l'inspecteur" : "Afficher l'inspecteur")
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private static func overlayName(_ kind: Overlay.Kind) -> String {
        switch kind {
        case .text: "Un texte"
        case .arrow: "Une flèche"
        case .box: "Un cadre"
        }
    }

    /// The title, editable in place, and what the edit does to the length; sharing progress takes its place.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Titre", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.title(20))
                .focused($titleFocused)
                .onSubmit(saveTitle)
                .onChange(of: titleFocused) { if !titleFocused { saveTitle() } }
            Spacer(minLength: 12)
            if sharing == .idle || isSettled {
                lengthSummary
            } else {
                shareStatus
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, Theme.Spacing.section)
        .padding(.bottom, Theme.Spacing.row)
    }

    @ViewBuilder private var lengthSummary: some View {
        let edited = edit.editedDuration(duration: item.duration)
        HStack(spacing: 8) {
            if edit.cuts.isEmpty {
                Text(ControlBar.format(item.duration))
            } else {
                Text("\(ControlBar.format(edited)) après montage")
                Text("·")
                Button("Tout remettre") { edit = Edit() }
                    .buttonStyle(.link)
                    .help("Annuler toutes les coupes")
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// A finished share stays in the header only until the next edit.
    @State private var isSettled = false

    private var isSharing: Bool {
        switch sharing {
        case .assembling, .uploading: true
        default: false
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panneau", selection: $tab) {
                ForEach(InspectorTab.allCases.filter { $0 != .agent || hasAgentPlan }, id: \.self) { tab in
                    Image(systemName: tab.symbol).accessibilityLabel(tab.rawValue).help(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.top, Theme.Spacing.row)
            Text(tab.rawValue)
                .font(Theme.title(15))
                .padding(.horizontal, Theme.Spacing.section)
                .padding(.top, Theme.Spacing.section)
                .padding(.bottom, Theme.Spacing.row)
            Group {
                switch tab {
                case .styling: StylingPanel(styling: $styling, duration: item.duration, onSeek: seek)
                case .share: SharePanel(item: item, clock: clock, details: $details)
                case .agent: AgentPanel(folder: agentFolder)
                case .ai: AIPanel(transcript: transcript, duration: item.duration, title: $title, details: $details, onSeek: seek, working: $aiWorking)
                case .transcript: transcriptPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder private var transcriptPanel: some View {
        if let transcript {
            let hesitations = suggestions.hesitations, silences = suggestions.silences
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                HStack(spacing: Theme.Spacing.small) {
                    Button("Hésitations (\(hesitations.count))") { edit.cuts += hesitations }
                        .disabled(hesitations.isEmpty)
                        .help("Couper les « euh » et les reprises")
                    Button("Silences (\(silences.count))") { edit.cuts += silences }
                        .disabled(silences.isEmpty)
                        .help("Couper les blancs de plus d'une seconde")
                }
                .controlSize(.small)
                ScrollView {
                    TranscriptWords(words: transcript.words, cut: Set(transcript.words.indices.filter { isCut(transcript.words[$0]) }),
                                    clock: clock, onToggle: toggle)
                }
                Text("Clique sur un mot pour le couper, clique à nouveau pour le remettre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.section)
        } else {
            ContentUnavailableView("Pas de transcription", systemImage: "text.bubble",
                                   description: Text("La vidéo n'a pas de voix, ou la langue n'est pas prise en charge."))
        }
    }

    @ViewBuilder private var shareStatus: some View {
        switch sharing {
        case .assembling:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Préparation de la vidéo…") }
                .font(.callout).foregroundStyle(.secondary)
        case .uploading(let value):
            HStack(spacing: 10) {
                Text("Envoi · \(Int(value * 100)) %").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                PlayheadPill(progress: value).frame(width: 120)
            }
        case .done(let url?):
            HStack(spacing: 10) {
                Label("Lien copié", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(Theme.accentInk)
                Link("Ouvrir", destination: url).font(.callout)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).lineLimit(2)
        default:
            EmptyView()
        }
    }

    // MARK: Words

    private func isCut(_ word: TranscriptWord) -> Bool {
        let middle = (word.start + word.end) / 2
        return edit.cuts.contains { $0.contains(middle) }
    }

    private func toggle(_ word: TranscriptWord) {
        if isCut(word) {
            let middle = (word.start + word.end) / 2
            edit.cuts.removeAll { $0.contains(middle) }
        } else {
            edit.cut(words: [word])
        }
    }

    // MARK: Playback

    private func seek(_ time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func load() {
        title = item.title
        shareURL = item.shareURL
        player.replaceCurrentItem(with: AVPlayerItem(url: library.videoURL(for: item.id)))
        if let data = try? Data(contentsOf: editURL), let saved = try? JSONDecoder().decode(Edit.self, from: data) { edit = saved }
        if let data = try? Data(contentsOf: detailsURL), let saved = try? JSONDecoder().decode(SharedDetails.self, from: data) { details = saved }
        if let data = try? Data(contentsOf: stylingURL), let saved = try? JSONDecoder().decode(Styling.self, from: data) { styling = saved }
        Task {
            if let track = try? await AVURLAsset(url: library.videoURL(for: item.id)).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.height > 0 {
                videoAspect = size.width / size.height
            }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")) {
            transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        }
        computeSuggestions()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            MainActor.assumeIsolated {
                clock.time = time.seconds
                // Skip over cut ranges during preview, so playback matches the edited video.
                let duration = item.duration
                if let cut = edit.normalizedCuts(duration: duration).first(where: { $0.contains(time.seconds) && $0.upperBound - time.seconds > 0.05 }) {
                    seek(cut.upperBound)
                }
            }
        }
    }

    private func unload() {
        saveTitle()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }

    /// Finding hesitations reads the whole transcript and audio: once per video, not at every redraw.
    private func computeSuggestions() {
        guard let transcript else { return }
        suggestions = CleanupSuggestions(
            hesitations: levels.map { Cleanup.hesitations(in: transcript, levels: $0) } ?? Cleanup.hesitations(in: transcript),
            silences: levels?.silences(duration: item.duration) ?? Cleanup.silences(in: transcript, duration: item.duration)
        )
    }

    private func save() {
        try? JSONEncoder().encode(edit).write(to: editURL)
    }

    private func saveTitle() {
        var copy = item
        copy.title = title.isEmpty ? item.title : title
        try? library.save(copy)
        onChange()
    }

    private func addOverlay(_ kind: Overlay.Kind) {
        let rect: CGRect = switch kind {
        case .text: CGRect(x: 0.3, y: 0.75, width: 0.4, height: 0.09)
        case .arrow: CGRect(x: 0.42, y: 0.38, width: 0.16, height: 0.16)
        case .box: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.25)
        }
        styling.overlays.append(Overlay(kind: kind, rect: rect, start: currentTime, end: min(item.duration, currentTime + 4), text: kind == .text ? "Texte" : ""))
        tab = .styling
    }

    /// The frame on screen becomes the video's thumbnail, here and on the share page at the next share.
    private func setThumbnail() async {
        guard let jpeg = try? await Thumbnails.jpeg(from: library.videoURL(for: item.id), at: currentTime) else { return }
        try? jpeg.write(to: folder.appendingPathComponent("thumbnail.jpg"))
        if let preview = try? await Thumbnails.gif(from: library.videoURL(for: item.id), start: currentTime) {
            try? preview.write(to: folder.appendingPathComponent("preview.gif"))
        }
        onChange()
    }

    // MARK: Sharing

    private func share() async {
        guard let account = await CloudAccount.current() else {
            sharing = .failed("Aucun serveur de partage configuré. Ouvre Réglages › Stockage.")
            return
        }
        guard details.privacy != "password" || !details.password.isEmpty else {
            sharing = .failed("Choisis le mot de passe des spectateurs.")
            tab = .share
            return
        }
        saveTitle()
        isSettled = false
        sharing = .assembling
        do {
            let source = library.videoURL(for: item.id)
            var upload = source
            let duration: Double
            if edit.cuts.isEmpty && styling.isEmpty {
                duration = item.duration
            } else {
                upload = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).mp4")
                var styled = styling
                // Overlays were placed on the source timeline; move them onto the edited one.
                styled.overlays = styling.overlays.compactMap { overlay in
                    guard let start = edit.editedTime(forSourceTime: overlay.start, duration: item.duration) else { return nil }
                    var moved = overlay
                    moved.start = start
                    moved.end = start + (overlay.end - overlay.start)
                    return moved
                }
                duration = try await Composer.render(source, edit: edit, styling: styled, transcript: transcript, to: upload)
            }
            var metadata = ShareMetadata(title: title, duration: duration)
            metadata.description = details.summary
            metadata.cta = details.callToAction
            metadata.privacy = details.privacy
            if details.privacy == "password", !details.password.isEmpty { metadata.password = details.password }
            metadata.links = details.links.compactMap { link in
                guard let start = edit.editedTime(forSourceTime: link.start, duration: item.duration) else { return nil }
                let end = edit.editedTime(forSourceTime: link.end, duration: item.duration) ?? start + (link.end - link.start)
                return .init(start: start, end: end, label: link.label, url: link.url)
            }
            // Chapters move with the edit; a chapter whose start was cut begins at the next kept moment.
            metadata.chapters = details.chapters.compactMap { chapter in
                let kept = edit.keptRanges(duration: item.duration).first { $0.upperBound > chapter.time }
                let time = kept.map { max(chapter.time, $0.lowerBound) } ?? chapter.time
                return edit.editedTime(forSourceTime: time, duration: item.duration).map { .init(time: $0, title: chapter.title) }
            }
            if let transcript { metadata.captions = Captions.webVTT(from: transcript, edit: edit, duration: item.duration) }
            let client = CloudClient(account: account)
            sharing = .uploading(0)
            let uploaded = try await client.upload(upload, metadata: metadata) { value in
                Task { @MainActor in sharing = .uploading(value) }
            }
            if let thumbnail = try? Data(contentsOf: folder.appendingPathComponent("thumbnail.jpg")) {
                try? await client.uploadThumbnail(thumbnail, videoID: uploaded.id)
            }
            if let preview = try? Data(contentsOf: folder.appendingPathComponent("preview.gif")) {
                try? await client.uploadPreview(preview, videoID: uploaded.id)
            }
            if upload != source { try? FileManager.default.removeItem(at: upload) }
            // Only once the new video is online: if the upload fails, the old link still works.
            if let previous = shareURL?.lastPathComponent, previous != uploaded.id { try? await client.delete(videoID: previous) }
            var copy = item
            copy.title = title
            copy.shareURL = uploaded.url
            shareURL = uploaded.url
            try library.save(copy)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uploaded.url.absoluteString, forType: .string)
            sharing = .done(uploaded.url)
            onChange()
        } catch {
            sharing = .failed(error.localizedDescription)
        }
    }
}

@Observable
final class PlaybackClock {
    var time: Double = 0
}

struct CleanupSuggestions {
    var hesitations: [ClosedRange<Double>] = []
    var silences: [ClosedRange<Double>] = []
}

/// The transcript as clickable words. Only this view follows the playhead, and only the chips whose
/// state changes redraw.
private struct TranscriptWords: View {
    let words: [TranscriptWord]
    let cut: Set<Int>
    let clock: PlaybackClock
    let onToggle: (TranscriptWord) -> Void

    var body: some View {
        let current = currentIndex(at: clock.time)
        WordFlow(spacing: 2) {
            ForEach(words.indices, id: \.self) { index in
                WordChip(word: words[index], isCut: cut.contains(index), isCurrent: index == current) { onToggle(words[index]) }
                    .equatable()
            }
        }
    }

    /// Words are in time order: a binary search finds the one being spoken.
    private func currentIndex(at time: Double) -> Int? {
        var low = 0, high = words.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if time < words[middle].start { high = middle - 1 } else if time >= words[middle].end { low = middle + 1 } else { return middle }
        }
        return nil
    }
}

private struct WordChip: View, Equatable {
    static func == (a: WordChip, b: WordChip) -> Bool {
        a.word == b.word && a.isCut == b.isCut && a.isCurrent == b.isCurrent
    }

    let word: TranscriptWord
    let isCut: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Text(word.text)
            .strikethrough(isCut, color: Theme.accentInk)
            .foregroundStyle(isCut ? .secondary : .primary)
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
            .background(isCurrent ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isCut ? "Remettre ce mot" : "Couper ce mot")
            .accessibilityAction(named: isCut ? "Remettre" : "Couper", action)
    }
}

/// Lays words out left to right, wrapping like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 300, subviews: subviews)
        return CGSize(width: proposal.width ?? 300, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row.sizes {
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(y: CGFloat, height: CGFloat, sizes: [CGSize])] {
        var rows: [(y: CGFloat, height: CGFloat, sizes: [CGSize])] = []
        var current: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, !current.isEmpty {
                let height = current.map(\.height).max() ?? 0
                rows.append((y, height, current))
                y += height + spacing
                current = []
                x = 0
            }
            current.append(size)
            x += size.width + spacing
        }
        if !current.isEmpty { rows.append((y, current.map(\.height).max() ?? 0, current)) }
        return rows
    }
}

/// AppKit's native player. SwiftUI's VideoPlayer can't load its AVKit superclass in a SwiftPM-built app.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
