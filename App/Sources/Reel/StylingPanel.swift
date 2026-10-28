import ReelKit
import SwiftUI

/// The editor's Habillage tab: burned-in captions, a backdrop around the screen, and the annotations list.
struct StylingPanel: View {
    @Binding var styling: Styling
    @Binding var selection: Overlay.ID?
    let duration: Double
    /// Read only when an action needs the playhead: the panel doesn't redraw during playback.
    let clock: PlaybackClock
    let onSeek: (Double) -> Void

    private func remove(_ id: Overlay.ID) {
        if selection == id { selection = nil }
        styling.overlays.removeAll { $0.id == id }
    }

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
            InspectorSection("Annotations", hint: styling.overlays.isEmpty ? nil : "Clique une annotation sur la vidéo pour la déplacer, la redimensionner par son coin ou la supprimer avec ⌫.") {
                if styling.overlays.isEmpty {
                    InspectorPlaceholder("Ajoute un texte, une flèche ou un cadre depuis la barre d'outils, puis place-le sur la vidéo.")
                }
                ForEach($styling.overlays) { $overlay in
                    OverlayRow(
                        overlay: $overlay,
                        isSelected: selection == overlay.id,
                        duration: duration,
                        onSelect: {
                            selection = overlay.id
                            onSeek(overlay.start)
                        },
                        onStartHere: {
                            let length = overlay.end - overlay.start
                            overlay.start = min(clock.time, max(0, duration - 1))
                            overlay.end = min(duration, overlay.start + length)
                            selection = overlay.id
                        },
                        onRemove: { remove(overlay.id) }
                    )
                }
            }
            if !styling.isEmpty {
                InspectorHint("L'habillage est incrusté à l'export : le partage prend un peu plus de temps.")
            }
        }
    }

    static func name(_ kind: Overlay.Kind) -> String {
        switch kind {
        case .text: "Texte"
        case .arrow: "Flèche"
        case .box: "Cadre"
        }
    }

    static func symbol(_ kind: Overlay.Kind) -> String {
        switch kind {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        }
    }
}

/// One annotation in the inspector: what it is and its text on the first line, when it shows on the second.
private struct OverlayRow: View {
    @Binding var overlay: Overlay
    let isSelected: Bool
    let duration: Double
    let onSelect: () -> Void
    let onStartHere: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: StylingPanel.symbol(overlay.kind)).foregroundStyle(Theme.accentInk).frame(width: 16)
                if overlay.kind == .text {
                    TextField("Texte", text: $overlay.text).textFieldStyle(.roundedBorder)
                } else {
                    Text(StylingPanel.name(overlay.kind))
                    Spacer()
                }
                RemoveButton(help: "Supprimer l'annotation", action: onRemove)
            }
            HStack(spacing: Theme.Spacing.small) {
                Button("\(ControlBar.format(overlay.start)) – \(ControlBar.format(overlay.end))", action: onSelect)
                    .buttonStyle(.plain)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Aller au début de l'annotation")
                Button(action: onStartHere) { Image(systemName: "arrow.right.to.line") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Faire commencer l'annotation à la position de lecture")
                    .accessibilityLabel("Commencer à la position de lecture")
                Spacer()
                Stepper(value: length, in: 1...60) {
                    Text("\(Int(length.wrappedValue)) s").monospacedDigit().foregroundStyle(.secondary)
                }
                .help("Durée à l'écran")
            }
            .padding(.leading, 16 + Theme.Spacing.small)
        }
        .font(.callout)
        .padding(Theme.Spacing.small)
        .background(isSelected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Seconds on screen, never past the end of the video.
    private var length: Binding<Double> {
        Binding(
            get: { (overlay.end - overlay.start).rounded() },
            set: { overlay.end = min(duration, overlay.start + $0) }
        )
    }
}

/// Annotations over the player. Those active at the playhead show; a click selects one, which can then be
/// dragged, resized from its corner, retyped in place (text) or deleted with ⌫ or its close button.
struct OverlayCanvas: View {
    @Binding var styling: Styling
    @Binding var selection: Overlay.ID?
    let clock: PlaybackClock
    let videoAspect: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let currentTime = clock.time
        GeometryReader { geometry in
            let video = Self.fit(aspect: videoAspect, in: geometry.size)
            ZStack(alignment: .topLeading) {
                if selection != nil {
                    // Clicking beside the annotation lets go of it, as in Keynote.
                    Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil }
                }
                ForEach($styling.overlays) { $overlay in
                    if overlay.id == selection || (currentTime >= overlay.start && currentTime <= overlay.end) {
                        OverlayItem(
                            overlay: $overlay,
                            video: video,
                            isSelected: overlay.id == selection,
                            onSelect: {
                                selection = overlay.id
                                focused = true
                            },
                            onRemove: { remove(overlay.id) }
                        )
                    }
                }
            }
        }
        .focusable(selection != nil)
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { if let selection { remove(selection) } }
        .onExitCommand { selection = nil }
        .onChange(of: selection) { _, id in if id != nil { focused = true } }
    }

    private func remove(_ id: Overlay.ID) {
        selection = nil
        styling.overlays.removeAll { $0.id == id }
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

private struct OverlayItem: View {
    @Binding var overlay: Overlay
    /// Where the video sits in the canvas; the overlay's rect is in fractions of it.
    let video: CGRect
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var dragOrigin: CGRect?
    @State private var editing = false
    @FocusState private var textFocused: Bool

    private static let minimum: CGFloat = 0.04
    private static let handle: CGFloat = 12

    private var frame: CGRect {
        CGRect(x: video.minX + overlay.rect.minX * video.width, y: video.minY + overlay.rect.minY * video.height,
               width: overlay.rect.width * video.width, height: overlay.rect.height * video.height)
    }

    var body: some View {
        let frame = frame
        content
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(Theme.accent, lineWidth: 1.5).padding(-4)
                }
            }
            .onTapGesture {
                // A second click on a selected text types into it.
                if isSelected, overlay.kind == .text { editing = true; textFocused = true } else { onSelect() }
            }
            .gesture(move)
            .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
            .overlay(alignment: .topLeading) { if isSelected { closeButton } }
            .position(x: frame.midX, y: frame.midY)
            .onChange(of: isSelected) { _, selected in if !selected { editing = false } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(overlay.kind == .text ? "Texte : \(overlay.text)" : StylingPanel.name(overlay.kind))
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction(named: "Supprimer", onRemove)
    }

    @ViewBuilder private var content: some View {
        switch overlay.kind {
        case .box:
            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 3)
        case .arrow:
            ArrowShape().stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        case .text:
            Group {
                if editing {
                    TextField("Texte", text: $overlay.text)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($textFocused)
                        .onSubmit { editing = false }
                        .onChange(of: textFocused) { _, focused in if !focused { editing = false } }
                        .padding(.horizontal, Theme.Spacing.small)
                } else {
                    Text(overlay.text.isEmpty ? "Texte" : overlay.text)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
    }

    /// Follows the pointer from wherever the annotation was grabbed, inside the video.
    private var move: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = overlay.rect
                    if !isSelected { onSelect() }
                }
                guard let start = dragOrigin, video.width > 0, video.height > 0 else { return }
                let x = start.minX + value.translation.width / video.width
                let y = start.minY + value.translation.height / video.height
                overlay.rect.origin = CGPoint(x: min(max(0, x), 1 - start.width), y: min(max(0, y), 1 - start.height))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var resizeHandle: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
            .frame(width: Self.handle, height: Self.handle)
            .offset(x: Self.handle / 2 + 2, y: Self.handle / 2 + 2)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = overlay.rect }
                        guard let start = dragOrigin, video.width > 0, video.height > 0 else { return }
                        let width = start.width + value.translation.width / video.width
                        let height = start.height + value.translation.height / video.height
                        overlay.rect.size = CGSize(width: min(max(Self.minimum, width), 1 - start.minX),
                                                   height: min(max(Self.minimum, height), 1 - start.minY))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .help("Redimensionner")
            .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.black.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .offset(x: -13, y: -13)
        .help("Supprimer (⌫)")
        .accessibilityLabel("Supprimer l'annotation")
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
