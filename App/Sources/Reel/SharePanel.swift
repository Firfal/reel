import ReelKit
import SwiftUI

/// The editor's Partage tab: who can watch, clickable links in the video, and who watched.
struct SharePanel: View {
    let item: VideoItem
    let clock: PlaybackClock
    private var currentTime: Double { clock.time }
    @Binding var details: SharedDetails

    @State private var insights: CloudClient.Insights?
    @State private var insightsFailed = false
    @State private var newLinkLabel = ""
    @State private var newLinkURL = ""

    var body: some View {
        InspectorPage {
            InspectorSection("Qui peut regarder", hint: privacyHint) {
                Picker("Confidentialité", selection: $details.privacy) {
                    Text("Lien seulement").tag("unlisted")
                    Text("Public").tag("public")
                    Text("Mot de passe").tag("password")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
                .labelsHidden()
                if details.privacy == "password" {
                    SecureField("Mot de passe pour les spectateurs", text: $details.password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            InspectorSection("Liens dans la vidéo", hint: "Un bouton cliquable apparaît sur la vidéo pendant 5 secondes.") {
                ForEach(details.links, id: \.self) { link in
                    HStack {
                        Text("\(ControlBar.format(link.start))–\(ControlBar.format(link.end))").monospacedDigit().foregroundStyle(Theme.accentInk)
                        Text(link.label).lineLimit(1)
                        Spacer()
                        RemoveButton(help: "Retirer le lien") { details.links.removeAll { $0 == link } }
                    }
                    .font(.callout)
                }
                TextField("Texte du bouton", text: $newLinkLabel).textFieldStyle(.roundedBorder)
                TextField("https://…", text: $newLinkURL).textFieldStyle(.roundedBorder)
                Button {
                    guard let url = URL(string: newLinkURL), url.scheme?.hasPrefix("http") == true, !newLinkLabel.isEmpty else { return }
                    details.links.append(.init(start: currentTime, end: min(item.duration, currentTime + 5), label: newLinkLabel, url: url))
                    newLinkLabel = ""
                    newLinkURL = ""
                } label: {
                    // Only the label follows the playhead.
                    PlayheadLabel(clock: clock) { "Ajouter à \(ControlBar.format($0))" }
                }
                .controlSize(.small)
                .disabled(newLinkLabel.isEmpty || URL(string: newLinkURL)?.scheme?.hasPrefix("http") != true)
            }

            if item.shareURL != nil {
                InspectorSection("Qui a regardé") {
                    if let insights {
                        if insights.views.isEmpty { InspectorPlaceholder("Personne pour l'instant.") }
                        ForEach(insights.views, id: \.self) { view in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(view.viewer ?? "Anonyme").font(.callout)
                                    Spacer()
                                    Text("\(Int(view.percent)) %").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                PlayheadPill(progress: view.percent / 100, height: 3)
                            }
                        }
                        if !insights.comments.isEmpty {
                            Text("\(insights.comments.count) commentaire\(insights.comments.count > 1 ? "s" : "")").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, Theme.Spacing.small)
                            ForEach(insights.comments, id: \.id) { comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(comment.author).font(.callout.weight(.semibold))
                                        if let time = comment.time { Text(ControlBar.format(time)).font(.caption.monospacedDigit()).foregroundStyle(Theme.accentInk) }
                                    }
                                    Text(comment.body).font(.callout)
                                }
                            }
                        }
                    } else if insightsFailed {
                        HStack {
                            InspectorPlaceholder("Statistiques indisponibles.")
                            Button("Réessayer") { Task { await loadInsights() } }.buttonStyle(.link)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .task(id: item.shareURL) { await loadInsights() }
    }

    private var privacyHint: String {
        switch details.privacy {
        case "public": "Tout le monde peut trouver et regarder la vidéo."
        case "password": "Le lien demande le mot de passe avant de montrer la vidéo."
        default: "Seules les personnes qui ont le lien peuvent regarder. La page n'est pas référencée."
        }
    }

    private func loadInsights() async {
        guard let id = item.shareURL?.lastPathComponent else { return }
        insightsFailed = false
        guard let account = await CloudAccount.current(),
              let loaded = try? await CloudClient(account: account).insights(videoID: id) else {
            insightsFailed = true
            return
        }
        insights = loaded
    }
}

/// Text that follows the playhead without redrawing its container.
struct PlayheadLabel: View {
    let clock: PlaybackClock
    let text: (Double) -> String

    var body: some View { Text(text(clock.time)) }
}
