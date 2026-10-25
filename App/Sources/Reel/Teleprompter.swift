import ReelKit
import SwiftUI

/// Speaker notes that scroll slowly under the camera bubble, so you keep looking at the lens.
/// Never recorded (sharingType = .none).
@Observable
final class SpeakerNotes {
    var text: String {
        didSet { UserDefaults.standard.set(text, forKey: "speakerNotes") }
    }
    /// Points per second.
    var speed: Double = 14

    init() {
        text = UserDefaults.standard.string(forKey: "speakerNotes") ?? ""
    }
}

@MainActor
final class TeleprompterController {
    private var panel: NSPanel?

    func show(notes: SpeakerNotes, next anchor: NSRect?) {
        guard !notes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: TeleprompterView(notes: notes))
        place(next: anchor)
        panel.orderFrontRegardless()
    }

    /// Next to the camera bubble, so the eyes stay near the lens: on the screen side of it, flush with its outer
    /// edge. Without a bubble, centered at the top of the screen.
    func place(next anchor: NSRect?) {
        guard let panel else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let margin = Theme.Layout.screenMargin, gap = Theme.Layout.panelGap
        let size = NSSize(width: 360, height: 110)
        let origin: NSPoint
        if let anchor {
            let onLeft = anchor.midX < screen.midX
            let onBottom = anchor.midY < screen.midY
            origin = NSPoint(
                x: onLeft ? anchor.minX : anchor.maxX - size.width,
                y: onBottom ? anchor.maxY + gap : anchor.minY - gap - size.height
            )
        } else {
            origin = NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - margin - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: panel.isVisible)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = DemoMode.isOn ? .readOnly : .none
        return panel
    }
}

private struct TeleprompterView: View {
    let notes: SpeakerNotes
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation) { context in
            let offset = context.date.timeIntervalSince(start) * notes.speed
            Text(notes.text)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .offset(y: 70 - offset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.control))
        .onTapGesture { start = .now }
        .help("Clic pour reprendre au début")
    }
}

/// Notes editor in the menu bar panel, with dictation that the AI turns into talking points.
struct NotesEditor: View {
    @Bindable var notes: SpeakerNotes
    @State private var dictation = Dictation()
    @State private var structuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Écris ou dicte : l'IA en fait des points courts.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(dictation.isListening ? "Arrêter" : "Dicter") {
                    Task {
                        if dictation.isListening {
                            let spoken = await dictation.stop()
                            guard !spoken.isEmpty else { return }
                            structuring = true
                            notes.text = (try? await VideoAI.talkingPoints(from: spoken)) ?? spoken
                            structuring = false
                        } else {
                            await dictation.start()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(structuring)
            }
            TextEditor(text: $notes.text)
                .font(.callout)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            if dictation.isListening { Text(dictation.partial.isEmpty ? "J'écoute…" : dictation.partial).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if structuring { ProgressView("Mise en points…").controlSize(.small) }
        }
    }
}
