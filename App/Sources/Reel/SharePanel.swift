import ReelKit
import SwiftUI

/// The editor's Partage tab: who can watch, clickable links in the video, and who watched.
struct SharePanel: View {
    let item: VideoItem
    let currentTime: Double
    @Binding var details: SharedDetails

    @State private var insights: CloudClient.Insights?
    @State private var newLinkLabel = ""
    @State private var newLinkURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Qui peut regarder") {
                    Picker("Confidentialité", selection: $details.privacy) {
                        Text("Lien seulement").tag("unlisted")
                        Text("Public").tag("public")
                        Text("Mot de passe").tag("password")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if details.privacy == "password" {
                        SecureField("Mot de passe pour les spectateurs", text: $details.password)
                    }
                    Text(privacyHint).font(.caption).foregroundStyle(.secondary)
                }

                section("Liens dans la vidéo") {
                    ForEach(details.links, id: \.self) { link in
                        HStack {
                            Text("\(ControlBar.format(link.start))–\(ControlBar.format(link.end))").monospacedDigit().foregroundStyle(Theme.accentInk)
                            Text(link.label).lineLimit(1)
                            Spacer()
                            Button { details.links.removeAll { $0 == link } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                        .font(.callout)
                    }
                    TextField("Texte du bouton", text: $newLinkLabel)
                    TextField("https://…", text: $newLinkURL)
                    Button("Ajouter à \(ControlBar.format(currentTime)), pendant 5 s") {
                        guard let url = URL(string: newLinkURL), url.scheme?.hasPrefix("http") == true, !newLinkLabel.isEmpty else { return }
                        details.links.append(.init(start: currentTime, end: min(item.duration, currentTime + 5), label: newLinkLabel, url: url))
                        newLinkLabel = ""
                        newLinkURL = ""
                    }
                    .controlSize(.small)
                    .disabled(newLinkLabel.isEmpty || URL(string: newLinkURL)?.scheme?.hasPrefix("http") != true)
                }

                if item.shareURL != nil {
                    section("Qui a regardé") {
                        if let insights {
                            if insights.views.isEmpty { Text("Personne pour l'instant.").font(.callout).foregroundStyle(.secondary) }
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
                                Text("\(insights.comments.count) commentaire\(insights.comments.count > 1 ? "s" : "")").font(Theme.title(13)).foregroundStyle(.secondary).padding(.top, 6)
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
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
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
        guard let id = item.shareURL?.lastPathComponent, let account = CloudAccount.load() else { return }
        insights = try? await CloudClient(account: account).insights(videoID: id)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.title(13)).foregroundStyle(.secondary)
            content()
        }
    }
}
