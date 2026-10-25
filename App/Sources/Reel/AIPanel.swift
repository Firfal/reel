import ReelKit
import SwiftUI

/// What the user kept from the AI's proposals, saved next to the video as insights.json and sent with the share.
struct SharedDetails: Codable, Hashable {
    init() {}

    init(from decoder: any Decoder) throws {
        // Every field is optional on disk, so older insights.json files still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        chapters = try container.decodeIfPresent([ShareMetadata.Chapter].self, forKey: .chapters) ?? []
        tasks = try container.decodeIfPresent([String].self, forKey: .tasks) ?? []
        ctaLabel = try container.decodeIfPresent(String.self, forKey: .ctaLabel) ?? ""
        ctaURL = try container.decodeIfPresent(String.self, forKey: .ctaURL) ?? ""
        privacy = try container.decodeIfPresent(String.self, forKey: .privacy) ?? "unlisted"
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        links = try container.decodeIfPresent([ShareMetadata.Link].self, forKey: .links) ?? []
    }

    var summary = ""
    var chapters: [ShareMetadata.Chapter] = []
    var tasks: [String] = []
    var ctaLabel = ""
    var ctaURL = ""
    var privacy = "unlisted"
    var password = ""
    var links: [ShareMetadata.Link] = []

    var callToAction: ShareMetadata.CallToAction? {
        guard !ctaLabel.isEmpty, let url = URL(string: ctaURL), url.scheme?.hasPrefix("http") == true else { return nil }
        return .init(label: ctaLabel, url: url)
    }
}

/// The AI tab of the editor: proposals from the on-device model, which the user edits before sharing.
struct AIPanel: View {
    let transcript: Transcript?
    let duration: Double
    @Binding var title: String
    @Binding var details: SharedDetails
    let onSeek: (Double) -> Void
    /// Owned by the editor, so a generation keeps running, and shows, across tab switches.
    @Binding var working: Bool

    @State private var error: String?
    @State private var confirmsRegenerate = false
    @State private var document: (kind: DocumentKind, text: String)?

    var body: some View {
        InspectorPage {
            HStack {
                Text("Proposé sur ton Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(hasProposals ? "Régénérer" : "Générer") {
                    if hasProposals { confirmsRegenerate = true } else { startGenerating() }
                }
                .disabled(working || transcript == nil)
                .confirmationDialog("Remplacer le résumé, les chapitres et les tâches ?", isPresented: $confirmsRegenerate) {
                    Button("Régénérer", role: .destructive) { startGenerating() }
                } message: {
                    Text("Tes modifications seront perdues.")
                }
            }
            if working { ProgressView("Analyse de la vidéo…").controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }

            InspectorSection("Résumé") {
                TextEditor(text: $details.summary)
                    .font(.callout)
                    .frame(minHeight: 72)
                    .insetField()
            }

            InspectorSection("Chapitres") {
                // By start time: the title changes with every keystroke, and identity must not.
                ForEach($details.chapters, id: \.time) { $chapter in
                    HStack(spacing: 8) {
                        Button(ControlBar.format(chapter.time)) { onSeek(chapter.time) }
                            .buttonStyle(.plain)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.accentInk)
                        TextField("Titre du chapitre", text: $chapter.title).textFieldStyle(.roundedBorder).font(.callout)
                        RemoveButton(help: "Retirer le chapitre") { details.chapters.removeAll { $0.time == chapter.time } }
                    }
                }
                if details.chapters.isEmpty { InspectorPlaceholder("Aucun chapitre.") }
            }

            InspectorSection("Tâches") {
                ForEach(details.tasks, id: \.self) { task in
                    Label(task, systemImage: "circle").font(.callout)
                }
                if details.tasks.isEmpty { InspectorPlaceholder("Aucune tâche mentionnée.") }
            }

            InspectorSection("Bouton d'action", hint: ctaHint) {
                TextField("Libellé, ex. Réserver un appel", text: $details.ctaLabel).textFieldStyle(.roundedBorder)
                TextField("Lien, ex. https://cal.com/toi", text: $details.ctaURL).textFieldStyle(.roundedBorder)
            }

            InspectorSection("Transformer en document") {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(DocumentKind.allCases) { kind in
                        Button(kind.label) { Task { await makeDocument(kind) } }
                            .disabled(working || transcript == nil)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } })) {
            if let document { DocumentSheet(kind: document.kind, text: document.text) }
        }
        .task(id: transcript == nil) {
            if !hasProposals, !working, transcript != nil { startGenerating() }
        }
    }

    private var hasProposals: Bool { !details.summary.isEmpty || !details.chapters.isEmpty || !details.tasks.isEmpty }

    /// A link that isn't a web address would be dropped from the share page without a word.
    private var ctaHint: String? {
        guard !details.ctaLabel.isEmpty || !details.ctaURL.isEmpty, details.callToAction == nil else { return nil }
        if details.ctaLabel.isEmpty { return "Ajoute un libellé pour afficher le bouton." }
        return details.ctaURL.isEmpty ? "Ajoute un lien pour afficher le bouton." : "Le lien doit commencer par https://."
    }

    /// Not tied to this view: switching tabs must not cancel the generation.
    private func startGenerating() {
        Task { await generate() }
    }

    private func generate() async {
        guard let transcript else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let insights = try await VideoAI.insights(for: transcript, duration: duration)
            if title.hasPrefix("Vidéo du") || title.isEmpty { title = insights.title }
            details.summary = insights.summary
            details.chapters = insights.chapters.map { .init(time: Double($0.start), title: $0.title) }
            details.tasks = insights.tasks
            if details.ctaLabel.isEmpty, let cta = insights.callToAction { details.ctaLabel = cta }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeDocument(_ kind: DocumentKind) async {
        guard let transcript else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            document = (kind, try await VideoAI.document(kind, for: transcript, title: title))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct DocumentSheet: View {
    let kind: DocumentKind
    @State var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    init(kind: DocumentKind, text: String) {
        self.kind = kind
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.label).font(Theme.title(17))
            TextEditor(text: $text)
                .font(.body)
                .insetField()
            HStack {
                Text("Généré sur ton Mac depuis la transcription").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fermer") { dismiss() }
                Button(copied ? "Copié" : "Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(Theme.Spacing.page)
        .frame(width: 560, height: 480)
    }
}
