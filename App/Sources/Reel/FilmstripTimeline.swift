import AVFoundation
import ReelKit
import SwiftUI

/// The editing timeline from « Sable »: a strip of frames from the video, so you edit by what you see.
/// Cut ranges are dimmed and hatched; the two outer handles trim the start and end; the playhead is Halo's pill head.
struct FilmstripTimeline: View {
    let videoURL: URL
    let duration: Double
    @Binding var edit: Edit
    let clock: PlaybackClock
    let onSeek: (Double) -> Void

    @State private var frames: [CGImage] = []
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (time: Double) in duration > 0 ? CGFloat(time / duration) * width : 0 }
            ZStack(alignment: .topLeading) {
                strip(width: width, height: geometry.size.height - 20)
                    .offset(y: 20)
                ForEach(Array(edit.normalizedCuts(duration: duration).enumerated()), id: \.offset) { _, cut in
                    CutMask()
                        .frame(width: max(2, x(cut.upperBound) - x(cut.lowerBound)), height: geometry.size.height - 20)
                        .offset(x: x(cut.lowerBound), y: 20)
                        .allowsHitTesting(false)
                }
                TimeRuler(duration: duration, width: width)
                    .frame(height: 16)
                Playhead(clock: clock, duration: duration, width: width, height: geometry.size.height)
                handle(at: x(trimStart), height: geometry.size.height - 20, leading: true) { location in
                    trimStart = min(max(0, Double(location / width) * duration), trimEnd - 0.5)
                    applyTrim()
                }
                handle(at: x(trimEnd), height: geometry.size.height - 20, leading: false) { location in
                    trimEnd = max(min(duration, Double(location / width) * duration), trimStart + 0.5)
                    applyTrim()
                }
            }
            .coordinateSpace(.named(Self.space))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(min(max(0, Double(value.location.x / width) * duration), duration))
            })
            .task(id: Int(width / 40)) { await loadFrames(count: max(4, Int(width / 72))) }
        }
        .onAppear(perform: readTrim)
        // « Tout remettre », or cuts from the transcript that reach an end, move the handles too.
        .onChange(of: edit) { readTrim() }
    }

    private static let space = "filmstrip"

    private func readTrim() {
        let cuts = edit.normalizedCuts(duration: duration)
        trimStart = cuts.first(where: { $0.lowerBound <= 0.01 })?.upperBound ?? 0
        trimEnd = cuts.last(where: { $0.upperBound >= duration - 0.01 })?.lowerBound ?? duration
    }

    private func strip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 1) {
            if frames.isEmpty {
                Theme.inset
            } else {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).stroke(Theme.line))
    }

    private func handle(at x: CGFloat, height: CGFloat, leading: Bool, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 10, height: height)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 18))
            .offset(x: leading ? x : x - 10, y: 20)
            // In the timeline's space: the handle's own space is only 10 points wide.
            .highPriorityGesture(DragGesture(coordinateSpace: .named(Self.space)).onChanged { value in onDrag(value.location.x) })
            .help(leading ? "Couper le début" : "Couper la fin")
            .pointerStyle(.columnResize)
    }

    private func applyTrim() {
        edit.cuts.removeAll { $0.lowerBound <= 0.01 || $0.upperBound >= duration - 0.01 }
        edit.trim(start: trimStart, end: trimEnd, duration: duration)
    }

    private func loadFrames(count: Int) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append(image) }
        }
        frames = images
    }
}

/// Hatched, dimmed overlay marking a cut range.
private struct CutMask: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
    }
}

private struct TimeRuler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        let step = Self.step(for: duration, width: width)
        Canvas { context, size in
            guard duration > 0 else { return }
            var t = 0.0
            while t <= duration {
                let x = CGFloat(t / duration) * size.width
                context.fill(Path(CGRect(x: x, y: size.height - 4, width: 1, height: 4)), with: .color(.secondary))
                // Labels sit just right of their tick, clear of the playhead resting on it; the last one turns left at the edge.
                let label = context.resolve(Text(ControlBar.format(t)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary))
                let labelWidth = label.measure(in: size).width
                let anchorRight = x + 9 + labelWidth > size.width
                context.draw(label, at: CGPoint(x: anchorRight ? x - 9 : x + 9, y: 5), anchor: anchorRight ? .trailing : .leading)
                t += step
            }
        }
    }

    static func step(for duration: Double, width: CGFloat) -> Double {
        let target = duration / max(1, Double(width / 90))
        return [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 >= target } ?? 600
    }
}

/// Halo's pill head on the timeline. Its own view, so following playback redraws only it, not the frames.
private struct Playhead: View {
    let clock: PlaybackClock
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let x = duration > 0 ? CGFloat(clock.time / duration) * width : 0
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.accent).frame(width: 2, height: height - 6).offset(y: 6)
            Circle()
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
        .offset(x: x - 6)
        .allowsHitTesting(false)
    }
}
