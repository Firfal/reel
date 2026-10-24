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
    @State private var currentTime: Double = 0
    @State private var sharing: AfterRecording = .idle
    @State private var shareURL: URL?
    @State private var timeObserver: Any?
    @State private var levels: AudioLevels?

    private var folder: URL { library.folder(for: item.id) }
    private var editURL: URL { folder.appendingPathComponent("edit.json") }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                PlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 320)
                FilmstripTimeline(
                    videoURL: library.videoURL(for: item.id),
                    duration: item.duration,
                    edit: $edit,
                    currentTime: currentTime,
                    onSeek: seek
                )
                .frame(height: 96)
                .padding(20)
            }
            .frame(minWidth: 560)
            inspector
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
        .background(Theme.canvas)
        .onAppear(perform: load)
        .onDisappear(perform: unload)
        .onChange(of: edit) { save() }
        .task { levels = try? await AudioLevels.measure(library.videoURL(for: item.id)) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Retour à la bibliothèque")
            TextField("Titre", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.title(17))
                .onSubmit(saveTitle)
            Spacer()
            Text("\(ControlBar.format(edit.editedDuration(duration: item.duration))) après montage")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: { Task { await share() } }) {
                Label(item.shareURL == nil ? "Partager" : "Mettre à jour le lien", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(isSharing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isSharing: Bool {
        switch sharing {
        case .assembling, .uploading: true
        default: false
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcription").font(Theme.title(15))
            if let transcript {
                let hesitations = levels.map { Cleanup.hesitations(in: transcript, levels: $0) } ?? Cleanup.hesitations(in: transcript)
                let silences = levels?.silences(duration: item.duration) ?? Cleanup.silences(in: transcript, duration: item.duration)
                HStack {
                    Button("Supprimer les hésitations (\(hesitations.count))") { edit.cuts += hesitations }
                        .disabled(hesitations.isEmpty)
                    Button("Les silences (\(silences.count))") { edit.cuts += silences }
                        .disabled(silences.isEmpty)
                }
                .controlSize(.small)
                ScrollView {
                    WordFlow(spacing: 1) {
                        ForEach(Array(transcript.words.enumerated()), id: \.offset) { _, word in
                            WordChip(
                                word: word,
                                isCut: isCut(word),
                                isCurrent: currentTime >= word.start && currentTime < word.end
                            ) { toggle(word) }
                        }
                    }
                }
                Text("Clique sur un mot pour le couper, clique à nouveau pour le remettre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Pas de transcription", systemImage: "text.bubble",
                                       description: Text("La vidéo n'a pas de voix, ou la langue n'est pas prise en charge."))
            }
            Spacer(minLength: 0)
            shareStatus
            if !edit.cuts.isEmpty {
                Button("Tout remettre", role: .destructive) { edit = Edit() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(18)
        .background(Theme.inset.opacity(0.5))
    }

    @ViewBuilder private var shareStatus: some View {
        switch sharing {
        case .assembling:
            Label("Préparation de la vidéo…", systemImage: "hourglass").font(.callout)
        case .uploading(let value):
            VStack(alignment: .leading, spacing: 6) {
                Text("Envoi vers ton Cloudflare · \(Int(value * 100)) %").font(.callout).foregroundStyle(.secondary)
                PlayheadPill(progress: value)
            }
        case .done(let url?):
            HStack {
                Label("Lien copié", systemImage: "link").font(.callout.weight(.medium))
                Spacer()
                Link("Ouvrir", destination: url).font(.callout)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
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
        player.replaceCurrentItem(with: AVPlayerItem(url: library.videoURL(for: item.id)))
        if let data = try? Data(contentsOf: editURL), let saved = try? JSONDecoder().decode(Edit.self, from: data) { edit = saved }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")) {
            transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            MainActor.assumeIsolated {
                currentTime = time.seconds
                // Skip over cut ranges during preview, so playback matches the edited video.
                let duration = item.duration
                if let cut = edit.normalizedCuts(duration: duration).first(where: { $0.contains(time.seconds) && $0.upperBound - time.seconds > 0.05 }) {
                    seek(cut.upperBound)
                }
            }
        }
    }

    private func unload() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
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

    // MARK: Sharing

    private func share() async {
        guard let account = CloudAccount.load() else {
            sharing = .failed("Aucun serveur de partage configuré. Ouvre Réglages › Stockage.")
            return
        }
        saveTitle()
        sharing = .assembling
        do {
            let source = library.videoURL(for: item.id)
            var upload = source
            let duration: Double
            if edit.cuts.isEmpty {
                duration = item.duration
            } else {
                upload = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).mp4")
                duration = try await Composer.render(source, edit: edit, to: upload)
            }
            var metadata = ShareMetadata(title: title, duration: duration)
            if let transcript { metadata.captions = Captions.webVTT(from: transcript, edit: edit, duration: item.duration) }
            let client = CloudClient(account: account)
            if let previous = item.shareURL?.lastPathComponent { try? await client.delete(videoID: previous) }
            sharing = .uploading(0)
            let uploaded = try await client.upload(upload, metadata: metadata) { value in
                Task { @MainActor in sharing = .uploading(value) }
            }
            if let thumbnail = try? Data(contentsOf: folder.appendingPathComponent("thumbnail.jpg")) {
                try? await client.uploadThumbnail(thumbnail, videoID: uploaded.id)
            }
            if upload != source { try? FileManager.default.removeItem(at: upload) }
            var copy = item
            copy.title = title
            copy.shareURL = uploaded.url
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

private struct WordChip: View {
    let word: TranscriptWord
    let isCut: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Text(word.text)
            .strikethrough(isCut, color: Theme.accentInk)
            .foregroundStyle(isCut ? .secondary : .primary)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(isCurrent ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(perform: action)
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
