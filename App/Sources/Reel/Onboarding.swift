import AVFoundation
import ReelKit
import SwiftUI

@MainActor
final class OnboardingController {
    private var window: NSWindow?
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    func show(startAt step: OnboardingView.Step = .permissions) {
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Bienvenue"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(step: step) { [weak window] in
            OnboardingController.isDone = true
            window?.close()
            NSApp.setActivationPolicy(.accessory)
        }.tint(Theme.accent))
        window.center()
        // Closed with the red button: back to a menu bar app, without a Dock icon.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
        }
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// First launch: permissions, where shared videos live, and which AI runs.
struct OnboardingView: View {
    enum Step: Int { case permissions, sharing, ai }

    @State var step: Step
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                PlayheadPill(progress: Double(step.rawValue + 1) / 3, height: 4).frame(width: 120)
                Text(title).font(Theme.title(26)).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("Étape \(step.rawValue + 1) sur 3").font(.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.page)
            .frame(width: 230, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(alignment: .top) { Theme.sidebarTint.ignoresSafeArea() }

            Group {
                switch step {
                case .permissions: PermissionsStep { step = .sharing }
                case .sharing: SharingStep { step = .ai }
                case .ai: AIStep(onFinish: onFinish)
                }
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        }
        .frame(width: 620, height: 520)
    }

    private var title: String {
        switch step {
        case .permissions: "Enregistre ton écran, ta voix et ta caméra."
        case .sharing: "Partage par lien, depuis ton propre Cloudflare."
        case .ai: "Titres, résumés et chapitres, écrits pour toi."
        }
    }

    private var subtitle: String {
        switch step {
        case .permissions: "macOS demande ton accord une fois pour chaque accès."
        case .sharing: "Gratuit, sans serveur central : tes vidéos restent chez toi."
        case .ai: "Sur ton Mac par défaut, ou avec Claude si tu as une clé."
        }
    }
}

private struct PermissionsStep: View {
    let onNext: () -> Void
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            row("Enregistrement de l'écran", granted: screen) {
                CGRequestScreenCaptureAccess()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            row("Caméra", granted: camera == .authorized) {
                // Once refused, macOS no longer asks: only System Settings can change the answer.
                guard camera == .notDetermined else { return Self.openPrivacy("Privacy_Camera") }
                AVCaptureDevice.requestAccess(for: .video) { _ in Task { @MainActor in camera = AVCaptureDevice.authorizationStatus(for: .video) } }
            }
            row("Micro", granted: microphone == .authorized) {
                guard microphone == .notDetermined else { return Self.openPrivacy("Privacy_Microphone") }
                AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in microphone = AVCaptureDevice.authorizationStatus(for: .audio) } }
            }
            Text("Pour l'écran, active Reel dans Réglages Système, puis reviens ici.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Continuer", action: onNext).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            screen = CGPreflightScreenCaptureAccess()
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private static func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func row(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Theme.accent : .secondary)
            Text(title)
            Spacer()
            if !granted { Button("Autoriser", action: action).controlSize(.small) }
        }
        .padding(Theme.Spacing.row)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

struct SharingStep: View {
    /// Nil in Settings, where there is no next step to skip to.
    var skipTitle: String? = "Garder les vidéos sur mon Mac"
    let onNext: () -> Void
    @State private var token = ""
    @State private var current: CloudSetup.Step?
    @State private var error: String?
    @State private var installed: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let installed {
                Label("Serveur installé", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accentInk)
                Text(installed.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                HStack {
                    Button("Réinstaller") { self.installed = nil }
                    Spacer()
                    Button("Continuer", action: onNext).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Text("1. Crée un compte gratuit sur Cloudflare et active R2 (une carte est demandée, rien n'est débité : Reel s'arrête avant de dépasser l'offre gratuite).")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Link("2. Crée un jeton d'API avec ces permissions :", destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CloudSetup.tokenPermissions, id: \.self) { Text("• \($0)").font(.caption.monospaced()) }
                }
                .padding(.leading, 12)
                Text("3. Colle-le ici :").font(.callout)
                SecureField("Jeton Cloudflare", text: $token)
                if let current {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(current.label).font(.callout) }
                    PlayheadPill(progress: Double((CloudSetup.Step.allCases.firstIndex(of: current) ?? 0) + 1) / Double(CloudSetup.Step.allCases.count))
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                HStack {
                    if let skipTitle { Button(skipTitle, action: onNext).buttonStyle(.link) }
                    Spacer()
                    Button("Installer") { Task { await install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.isEmpty || current != nil)
                }
            }
        }
        .task { installed = await CloudAccount.current()?.serverURL }
    }

    private func install() async {
        error = nil
        guard let script = Bundle.main.url(forResource: "index", withExtension: "js").flatMap({ try? Data(contentsOf: $0) }),
              let schema = Bundle.main.url(forResource: "schema", withExtension: "sql").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        else { error = "Fichiers du serveur introuvables dans l'app."; return }
        let font = Bundle.main.url(forResource: "InstrumentSans", withExtension: "ttf").flatMap { try? Data(contentsOf: $0) }
        do {
            let account = try await CloudSetup(token: token).run(workerScript: script, schema: schema, font: font) { step in
                Task { @MainActor in current = step }
            }
            try account.save()
            token = ""
            installed = account.serverURL
        } catch {
            self.error = error.localizedDescription
        }
        current = nil
    }
}

private struct AIStep: View {
    let onFinish: () -> Void
    @State private var engine = AIEngine.current
    @State private var key = ""
    @State private var hasKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Moteur", selection: $engine) {
                Text("Sur ton Mac — gratuit et privé").tag(AIEngine.onDevice)
                Text("Claude — avec ta clé d'API").tag(AIEngine.claude)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if engine == .onDevice, let reason = VideoAI.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            if engine == .claude {
                SecureField(hasKey ? "Clé enregistrée" : "sk-ant-…", text: $key)
                Text("La transcription est envoyée à Claude pour écrire titres, résumés et documents.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Commencer") {
                    AIEngine.current = engine
                    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty { try? ClaudeKey.save(key) }
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .task { hasKey = await ClaudeKey.current() != nil }
    }
}
