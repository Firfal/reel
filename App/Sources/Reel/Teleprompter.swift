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
    let dictation = Dictation()
    private(set) var structuring = false

    func toggleDictation() async {
        if dictation.isListening { await finishDictation() } else { await dictation.start() }
    }

    /// Stops listening and turns what was said into talking points.
    func finishDictation() async {
        guard dictation.isListening else { return }
        let spoken = await dictation.stop()
        guard !spoken.isEmpty else { return }
        structuring = true
        text = (try? await VideoAI.talkingPoints(from: spoken)) ?? spoken
        structuring = false
    }

    init() {
        text = UserDefaults.standard.string(forKey: "speakerNotes") ?? ""
    }
}

@MainActor
final class TeleprompterController {
    private var panel: NSPanel?

    func show(notes: SpeakerNotes, model: AppModel? = nil, next anchor: NSRect?) {
        guard !notes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: TeleprompterView(notes: notes, model: model))
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
    /// Scrolls only while recording: still during the countdown and while paused. Without a model it always scrolls.
    let model: AppModel?
    @State private var clock = ScrollClock()

    var body: some View {
        TimelineView(.animation) { context in
            let offset = clock.advance(to: context.date, running: model.map { $0.recorderState == .recording } ?? true) * notes.speed
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
        .onTapGesture { clock.reset() }
        .help("Clic pour reprendre au début")
    }
}

/// Seconds of scrolling so far, counting only the frames where scrolling runs. Not observed: the timeline redraws it.
private final class ScrollClock {
    private var elapsed: TimeInterval = 0
    private var last: Date?

    func advance(to date: Date, running: Bool) -> TimeInterval {
        if running, let last { elapsed += min(date.timeIntervalSince(last), 0.1) }
        last = date
        return elapsed
    }

    func reset() { elapsed = 0 }
}

/// Notes editor in the menu bar panel, with dictation that the AI turns into talking points.
struct NotesEditor: View {
    @Bindable var notes: SpeakerNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Écris ou dicte : l'IA en fait des points courts.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(notes.dictation.isListening ? "Arrêter" : "Dicter") {
                    Task { await notes.toggleDictation() }
                }
                .controlSize(.small)
                .disabled(notes.structuring)
            }
            TextEditor(text: $notes.text)
                .font(.callout)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            if notes.dictation.isListening { Text(notes.dictation.partial.isEmpty ? "J'écoute…" : notes.dictation.partial).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if notes.structuring { ProgressView("Mise en points…").controlSize(.small) }
        }
    }
}
