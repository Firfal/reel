import ReelKit
import SwiftUI

/// The editor's Habillage tab: burned-in captions, a backdrop around the screen, and the annotations list.
struct StylingPanel: View {
    @Binding var styling: Styling
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        InspectorPage {
            InspectorSection("Sous-titres dans la vidéo", hint: "La page de partage propose aussi ses propres sous-titres, activables par le spectateur.") {
                Picker("Sous-titres", selection: $styling.captions) {
                    Text("Aucun").tag(CaptionStyle.none)
                    Text("Classique").tag(CaptionStyle.classic)
                    Text("Clair").tag(CaptionStyle.light)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            InspectorSection("Son", hint: "Monte une voix trop faible et calme une voix trop forte, sans saturer.") {
                HStack {
                    Text("Voix au bon niveau")
                    Spacer()
                    Toggle("Voix au bon niveau", isOn: $styling.enhancesAudio)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Theme.accent)
                }
            }
            InspectorSection("Arrière-plan", hint: "L'écran est posé sur un fond, avec des coins arrondis et une ombre.") {
                Picker("Arrière-plan", selection: $styling.backdrop) {
                    Text("Aucun").tag(Backdrop.none)
                    Text("Dégradé").tag(Backdrop.gradient)
                    Text("Graphite").tag(Backdrop.graphite)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            InspectorSection("Annotations") {
                if styling.overlays.isEmpty {
                    InspectorPlaceholder("Ajoute un texte, une flèche ou un cadre depuis la barre d'outils, puis place-le sur la vidéo.")
                }
                ForEach($styling.overlays) { $overlay in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(overlay.kind)).foregroundStyle(Theme.accentInk).frame(width: 16)
                        Button("\(ControlBar.format(overlay.start))–\(ControlBar.format(overlay.end))") { onSeek(overlay.start) }
                            .buttonStyle(.plain).font(.callout.monospacedDigit())
                        if overlay.kind == .text {
                            TextField("Texte", text: $overlay.text).textFieldStyle(.roundedBorder).font(.callout)
                        } else {
                            Spacer()
                        }
                        Stepper(value: length($overlay), in: 1...60) {
                            Text("\(Int(overlay.end - overlay.start)) s").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help("Durée à l'écran")
                        RemoveButton(help: "Retirer l'annotation") { styling.overlays.removeAll { $0.id == overlay.id } }
                    }
                }
            }
            if !styling.isEmpty {
                InspectorHint("L'habillage est incrusté à l'export : le partage prend un peu plus de temps.")
            }
        }
    }

    /// Seconds on screen, never past the end of the video.
    private func length(_ overlay: Binding<Overlay>) -> Binding<Double> {
        Binding(
            get: { (overlay.wrappedValue.end - overlay.wrappedValue.start).rounded() },
            set: { overlay.wrappedValue.end = min(duration, overlay.wrappedValue.start + $0) }
        )
    }

    static func symbol(_ kind: Overlay.Kind) -> String {
        switch kind {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        }
    }
}

/// Annotations active at the current time, drawn over the player and draggable to reposition.
struct OverlayCanvas: View {
    @Binding var styling: Styling
    let clock: PlaybackClock
    let videoAspect: CGFloat

    var body: some View {
        let currentTime = clock.time
        GeometryReader { geometry in
            let video = Self.fit(aspect: videoAspect, in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach($styling.overlays) { $overlay in
                    if currentTime >= overlay.start && currentTime <= overlay.end {
                        shape(overlay)
                            .frame(width: overlay.rect.width * video.width, height: overlay.rect.height * video.height)
                            .position(x: video.minX + overlay.rect.midX * video.width, y: video.minY + overlay.rect.midY * video.height)
                            .gesture(DragGesture().onChanged { value in
                                let x = (value.location.x - video.minX) / video.width - overlay.rect.width / 2
                                let y = (value.location.y - video.minY) / video.height - overlay.rect.height / 2
                                overlay.rect.origin = CGPoint(x: min(max(0, x), 1 - overlay.rect.width), y: min(max(0, y), 1 - overlay.rect.height))
                            })
                    }
                }
            }
        }
    }

    @ViewBuilder private func shape(_ overlay: Overlay) -> some View {
        switch overlay.kind {
        case .box:
            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 3).contentShape(Rectangle())
        case .arrow:
            ArrowShape().stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)).contentShape(Rectangle())
        case .text:
            Text(overlay.text.isEmpty ? "Texte" : overlay.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
    }

    /// The rect a video of `aspect` occupies when fitted in `size`.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

nonisolated private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 16
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7), y: end.y - head * sin(angle - .pi / 7)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7), y: end.y - head * sin(angle + .pi / 7)))
        return path
    }
}
