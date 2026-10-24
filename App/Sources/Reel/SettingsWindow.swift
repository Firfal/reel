import ReelKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Réglages"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView().tint(Theme.accent))
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { if NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) }).count <= 1 { NSApp.setActivationPolicy(.accessory) } }
        }
        return window
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Stockage", systemImage: "externaldrive.connected.to.line.below") { StorageSettings() }
            Tab("IA", systemImage: "sparkles") { AISettings() }
            Tab("Image de marque", systemImage: "paintbrush") { BrandSettings() }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
            LabeledContent("Enregistrer ou arrêter", value: "⌥⇧R")
            LabeledContent("Bibliothèque", value: Library.defaultRoot.path)
            Button("Afficher dans le Finder") { NSWorkspace.shared.open(Library.defaultRoot) }
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    @State private var account = CloudAccount.load()
    @State private var usage: ServerUsage?
    @State private var error: String?

    var body: some View {
        Form {
            if let account {
                LabeledContent("Serveur de partage", value: account.serverURL.host() ?? account.serverURL.absoluteString)
                if let usage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Stockage utilisé")
                            Spacer()
                            Text("\(Self.gigabytes(usage.storageBytes)) sur \(Self.gigabytes(usage.storageCapBytes))").monospacedDigit().foregroundStyle(.secondary)
                        }
                        PlayheadPill(progress: Double(usage.storageBytes) / Double(max(usage.storageCapBytes, 1)))
                        Text("L'envoi s'arrête avant de dépasser l'offre gratuite de Cloudflare : ton compte ne paie jamais.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Lectures ce mois-ci", value: "\(usage.readOps.formatted()) sur \(usage.readOpsCap.formatted())")
                    LabeledContent("Envois ce mois-ci", value: "\(usage.writeOps.formatted()) sur \(usage.writeOpsCap.formatted())")
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Text("Aucun serveur de partage. Les vidéos restent sur ton Mac.")
                SharingStep { self.account = CloudAccount.load() }
            }
        }
        .formStyle(.grouped)
        .task {
            guard let account else { return }
            do { usage = try await CloudClient(account: account).usage() } catch { self.error = error.localizedDescription }
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

private struct AISettings: View {
    @State private var engine = AIEngine.current
    @State private var key = ""
    @State private var hasKey = ClaudeKey.load() != nil
    @State private var saved = false

    var body: some View {
        Form {
            Picker("Moteur", selection: $engine) {
                Text("Sur ton Mac (Apple Intelligence)").tag(AIEngine.onDevice)
                Text("Claude, avec ta clé").tag(AIEngine.claude)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: engine) { AIEngine.current = engine }
            if engine == .onDevice {
                if let reason = VideoAI.unavailableReason {
                    Text(reason).foregroundStyle(.orange)
                } else {
                    Text("Gratuit et privé : la vidéo et sa transcription ne quittent pas ton Mac.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                SecureField(hasKey ? "Clé enregistrée — colle une nouvelle clé pour la remplacer" : "sk-ant-…", text: $key)
                HStack {
                    Button("Enregistrer la clé") {
                        guard !key.isEmpty else { return }
                        try? ClaudeKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        key = ""
                        hasKey = true
                        saved = true
                    }
                    .disabled(key.isEmpty)
                    if saved { Text("Enregistrée dans le Trousseau").font(.caption).foregroundStyle(.secondary) }
                }
                Text("La transcription est envoyée à Claude pour écrire titres, résumés et documents. La clé reste dans ton Trousseau.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BrandSettings: View {
    @State private var branding: CloudClient.Branding?
    @State private var color = Color(light: 0xE2703A, dark: 0xE2703A)
    @State private var status: String?
    private let account = CloudAccount.load()

    var body: some View {
        Form {
            if account == nil {
                Text("Configure d'abord un serveur de partage dans l'onglet Stockage.")
            } else if let binding = Binding($branding) {
                TextField("Nom affiché sur la page", text: binding.companyName, prompt: Text("ex. Acme Studio"))
                ColorPicker("Couleur du lecteur", selection: $color, supportsOpacity: false)
                LabeledContent("Logo") {
                    Button(binding.wrappedValue.hasLogo ? "Remplacer le logo…" : "Choisir un logo…", action: pickLogo)
                }
                Picker("Confidentialité par défaut", selection: binding.defaultPrivacy) {
                    Text("Lien seulement").tag("unlisted")
                    Text("Public").tag("public")
                    Text("Mot de passe").tag("password")
                }
                HStack {
                    Button("Enregistrer") { Task { await save() } }.buttonStyle(.borderedProminent)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                Text("La page de partage n'affiche jamais le logo de Reel : seulement ton nom ou ton logo.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .task {
            guard let account, let loaded = try? await CloudClient(account: account).branding() else { return }
            branding = loaded
            color = Color(hex: loaded.playerColor) ?? color
        }
    }

    private func save() async {
        guard let account, var branding else { return }
        branding.playerColor = color.hexString
        do {
            self.branding = try await CloudClient(account: account).saveBranding(branding)
            status = "Enregistré"
        } catch {
            status = error.localizedDescription
        }
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        guard panel.runModal() == .OK, let url = panel.url, let account else { return }
        Task {
            guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            do {
                try await CloudClient(account: account).uploadLogo(png)
                branding?.hasLogo = true
                status = "Logo envoyé"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(light: value, dark: value)
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
