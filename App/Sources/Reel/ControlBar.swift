import AppKit
import SwiftUI

/// The floating bar shown while recording. It is never captured (sharingType = .none), except in demo mode.
@MainActor
final class ControlBarController {
    private var panel: NSPanel?

    func show(model: AppModel, onStop: @escaping () -> Void, onCancel: @escaping () -> Void, onDraw: @escaping () -> Void, onBlur: @escaping () -> Void = {}) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ControlBar(model: model, onStop: onStop, onCancel: onCancel, onDraw: onDraw, onBlur: onBlur))
        panel.setContentSize(panel.contentView!.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 28))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = DemoMode.isOn ? .readOnly : .none
        return panel
    }
}

struct ControlBar: View {
    let model: AppModel
    let onStop: () -> Void
    let onCancel: () -> Void
    let onDraw: () -> Void
    var onBlur: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if let countdown = model.countdown {
                Text("\(countdown)")
                    .font(Theme.title(17))
                    .monospacedDigit()
                    .frame(width: 120)
                    .contentTransition(.numericText(countsDown: true))
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.recorderState == .recording ? Theme.accent : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(Self.format(model.recordedDuration))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        // The signature: a slim pill with a round playhead, here filling one turn per minute.
                        PlayheadPill(progress: model.recordedDuration.truncatingRemainder(dividingBy: 60) / 60)
                            .frame(width: 56)
                    }
                    .padding(.leading, 6)
                }
            }
            Divider().frame(height: 18)
            BarButton(symbol: model.recorderState == .paused ? "play.fill" : "pause.fill",
                      help: model.recorderState == .paused ? "Reprendre" : "Pause") { Task { await model.togglePause() } }
            BarButton(symbol: "gobackward.5", help: "Revenir 5 s en arrière") { Task { await model.rewind() } }
            BarButton(symbol: "pencil.tip", help: "Dessiner à l'écran") { onDraw() }
            BarButton(symbol: "eye.slash", help: "Flouter une zone (double-clic pour la retirer)") { onBlur() }
            BarButton(symbol: "trash", help: "Annuler l'enregistrement") { onCancel() }
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.plain)
            .help("Terminer")
            .keyboardShortcut(.return, modifiers: [.option, .shift])
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .padding(10)
        .animation(Theme.Motion.standard, value: model.countdown)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Halo's signature element: a slim track with a round playhead. Used everywhere progress shows.
struct PlayheadPill: View {
    var progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width * min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.18))
                Capsule().fill(Theme.accent).frame(width: x)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: height * 2.5, height: height * 2.5)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .offset(x: x - height * 1.25)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height * 2.5)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(hovering ? Theme.accentSoft : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
