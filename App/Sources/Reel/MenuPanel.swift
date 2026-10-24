import AVFoundation
import ReelKit
import SwiftUI

/// The panel that opens from the menu bar: choose what to record, then record.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Bindable var bubble: BubbleSettings
    let onRecord: () -> Void
    let onOpenLibrary: () -> Void

    private var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }
    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Group {
                Row(symbol: "video", title: "Caméra") {
                    Picker("Caméra", selection: $model.cameraID) {
                        Text("Aucune").tag(String?.none)
                        ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag(String?.some($0.uniqueID)) }
                    }
                    .labelsHidden().frame(maxWidth: 190)
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
                }
                Row(symbol: "mic", title: "Micro") {
                    Picker("Micro", selection: $model.microphoneID) {
                        Text("Aucun").tag(String?.none)
                        Text("Micro par défaut").tag(String?.some(MicrophoneDevice.systemDefaultID))
                        ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag(String?.some($0.uniqueID)) }
                    }
                    .labelsHidden().frame(maxWidth: 190)
                }
            }

            VStack(spacing: 0) {
                ToggleRow(title: "Son du système", isOn: $model.capturesSystemAudio)
                ToggleRow(title: "Masquer les notifications", isOn: $model.doNotDisturb)
                ToggleRow(title: "Masquer les icônes du bureau", isOn: $model.hidesDesktop)
                ToggleRow(title: "Montrer les clics", isOn: $model.highlightsClicks)
                ToggleRow(title: "Pour un agent : capter clics et adresses", isOn: $model.agentMode)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.control))

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
            .keyboardShortcut(.defaultAction)

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
            HStack {
                Button("Ouvrir la bibliothèque", action: onOpenLibrary).buttonStyle(.link)
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.link).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .tint(Theme.accentInk)
        .focusEffectDisabled()
        .background(alignment: .top) { Theme.sidebarTint.frame(height: 140) }
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
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title).fixedSize()
            Spacer(minLength: 8)
            content
        }
        .font(.callout)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
