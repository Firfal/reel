import AVFoundation
import ReelKit
import SwiftUI

/// The panel that opens from the menu bar: choose what to record, then record.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Bindable var bubble: BubbleSettings
    var notes = SpeakerNotes()
    @State private var showsNotes = false
    let onRecord: () -> Void
    let onOpenLibrary: () -> Void
    var onOpenSettings: () -> Void = {}
    /// Called before a macOS window opens over the panel, so clicking in it keeps the panel open.
    var onSystemWindow: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Device discovery is slow: done when the panel appears and when a device comes or goes, not on every redraw.
    @State private var cameras: [Device] = []
    @State private var microphones: [Device] = []

    struct Device: Hashable {
        let id: String
        let name: String
    }

    private func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Nouvel enregistrement").font(Theme.title(15))
                Spacer()
                Picker("Qualité", selection: $model.quality) {
                    Text("720p").tag(CaptureQuality.p720)
                    Text("1080p").tag(CaptureQuality.p1080)
                    Text("1440p").tag(CaptureQuality.p1440)
                    Text("4K").tag(CaptureQuality.p2160)
                }
                .labelsHidden()
                .fixedSize()
            }

            Picker("Source", selection: $model.source) {
                ForEach(SourceKind.allCases) { kind in
                    Label(kind.label, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // One grid for every row: icon, label, then the control flush right.
            VStack(spacing: Self.rowSpacing) {
                Row(symbol: "video", title: "Caméra") {
                    Picker("Caméra", selection: $model.cameraID) {
                        Text("Aucune").tag(String?.none)
                        ForEach(cameras, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: Self.controlWidth)
                }
                if model.cameraID != nil {
                    Row(symbol: "square.on.circle", title: "Bulle") {
                        Picker("Forme", selection: $bubble.shape) {
                            ForEach(BubbleShape.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("Taille", selection: $bubble.size) {
                            ForEach(BubbleSize.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Row(symbol: "wand.and.stars", title: "Effets") {
                        Button("Réglages vidéo…") {
                            onSystemWindow()
                            AVCaptureDevice.showSystemUserInterface(.videoEffects)
                        }
                            .help("Flou d'arrière-plan, arrière-plans, éclairage studio : les effets vidéo de macOS")
                    }
                }
            }
            VStack(spacing: Self.rowSpacing) {
                Row(symbol: "mic", title: "Micro") {
                    Picker("Micro", selection: $model.microphoneID) {
                        Text("Aucun").tag(String?.none)
                        Text("Micro par défaut").tag(String?.some(MicrophoneDevice.systemDefaultID))
                        ForEach(microphones, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: Self.controlWidth)
                }
                if model.microphoneID != nil {
                    Row(symbol: "waveform.and.mic", title: "Bruit de fond") {
                        Button("Isolation de la voix…") {
                            onSystemWindow()
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                            .help("Ouvre les modes micro de macOS : « Isolation de la voix » retire le bruit de fond.")
                    }
                }
                ToggleRow(symbol: "speaker.wave.2", title: "Son du système", isOn: $model.capturesSystemAudio)
            }
            VStack(spacing: Self.rowSpacing) {
                ToggleRow(symbol: "bell.slash", title: "Masquer les notifications", isOn: $model.doNotDisturb)
                ToggleRow(symbol: "menubar.dock.rectangle", title: "Masquer les icônes du bureau", isOn: $model.hidesDesktop)
                ToggleRow(symbol: "cursorarrow.click", title: "Montrer les clics", isOn: $model.highlightsClicks)
                ToggleRow(symbol: "cursorarrow.rays", title: "Pour un agent", isOn: $model.agentMode)
                    .help("Capte chaque clic, la fenêtre et l'adresse de la page, pour en faire un plan qu'un agent peut suivre")
                Row(symbol: "text.alignleft", title: "Téléprompteur") {
                    Button {
                        withAnimation(Theme.Motion.standard) { showsNotes.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(notes.text.isEmpty ? "Ajouter" : "Modifier")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showsNotes ? 180 : 0)).font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if showsNotes {
                    NotesEditor(notes: notes)
                        .transition(.opacity)
                }
            }

            Button(action: onRecord) {
                HStack {
                    Circle().fill(Theme.onAccent).frame(width: 8, height: 8)
                    Text("Enregistrer").fontWeight(.semibold)
                    Spacer()
                    Text("⌥⇧R").font(.system(size: 12, weight: .medium).monospaced()).opacity(0.7)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .keyboardShortcut(showsNotes ? nil : .defaultAction)  // Return types a new line in the notes

            if model.needsScreenPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reel n'a pas encore le droit d'enregistrer l'écran.").font(.callout.weight(.medium))
                    Text("Active Reel dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran, puis relance Reel.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Ouvrir les réglages") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .controlSize(.small)
                }
            }

            AfterRecordingRow(after: model.after)

            if let error = model.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Divider()
            HStack(spacing: 14) {
                FooterButton(title: "Bibliothèque", action: onOpenLibrary).foregroundStyle(Theme.accentInk)
                Spacer()
                FooterButton(title: "Réglages", action: onOpenSettings).keyboardShortcut(",", modifiers: .command)
                FooterButton(title: "Quitter") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 340)
        .tint(Theme.accentInk)
        .focusEffectDisabled()
        .background(alignment: .top) { Theme.sidebarTint.frame(height: 140) }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshDevices)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }
}

extension MenuPanel {
    static let rowSpacing: CGFloat = 10
    static let controlWidth: CGFloat = 170
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

/// Bubble shape and size, shared by the panel and the bubble window.
@Observable
final class BubbleSettings {
    var shape: BubbleShape = .squircle
    var size: BubbleSize = .medium
}

private struct Row<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title).fixedSize()
            Spacer(minLength: 8)
            content
                .controlSize(.small)
        }
        .font(.callout)
        .frame(minHeight: 24)
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Row(symbol: symbol, title: title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
    }
}

private struct AfterRecordingRow: View {
    let after: AfterRecording
    var body: some View {
        switch after {
        case .idle:
            EmptyView()
        case .assembling:
            status("Assemblage de la vidéo…", progress: nil)
        case .transcribing:
            status("Transcription sur ton Mac…", progress: nil)
        case .uploading(let value):
            status("Envoi vers ton Cloudflare · \(Int(value * 100)) %", progress: value)
        case .done(let url?):
            HStack {
                Image(systemName: "link").foregroundStyle(Theme.accentInk)
                Text("Lien copié").fontWeight(.medium)
                Spacer()
                Link("Ouvrir", destination: url)
            }
            .font(.callout)
        case .done(nil):
            Label("Vidéo enregistrée dans Films › Reel", systemImage: "checkmark.circle").font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
        }
    }

    private func status(_ text: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if let progress { PlayheadPill(progress: progress) } else { ProgressView().controlSize(.small) }
        }
    }
}
