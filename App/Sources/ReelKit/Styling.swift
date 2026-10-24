import AVFoundation
import AppKit
import QuartzCore

/// An annotation drawn over the video for a while: a text label, an arrow or a box.
public struct Overlay: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, arrow, box }

    public var id = UUID()
    public var kind: Kind
    /// Position and size as fractions of the video frame, origin top-left.
    public var rect: CGRect
    public var start: Double
    public var end: Double
    public var text: String

    public init(kind: Kind, rect: CGRect, start: Double, end: Double, text: String = "") {
        self.kind = kind
        self.rect = rect
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum CaptionStyle: String, Codable, Sendable, CaseIterable {
    /// No burned-in captions (the share page still offers its own).
    case none
    /// White text on a dark pill.
    case classic
    /// Dark text on a white pill, the current word in the accent color.
    case light
}

public enum Backdrop: String, Codable, Sendable, CaseIterable {
    case none
    /// The screen sits inset on a soft warm gradient, with rounded corners and a shadow.
    case gradient
    /// Same inset, on a plain graphite background.
    case graphite
}

/// Everything burned into the exported picture.
public struct Styling: Codable, Sendable, Hashable {
    public var overlays: [Overlay] = []
    public var captions: CaptionStyle = .none
    public var backdrop: Backdrop = .none
    /// Accent for arrows, boxes and highlighted words, as 0xRRGGBB.
    public var accent: UInt32 = 0xE2703A

    public init() {}

    public var isEmpty: Bool { overlays.isEmpty && captions == .none && backdrop == .none }
}

extension Composer {
    /// Exports `source` with `edit` applied and `styling` burned into the picture. Re-encodes, so it is slower
    /// than `render`; used only when there is something to draw.
    @concurrent
    public static func render(_ source: URL, edit: Edit, styling: Styling, transcript: Transcript?, to destination: URL) async throws -> Double {
        guard !styling.isEmpty else { return try await render(source, edit: edit, to: destination) }
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: cut) }
        let duration = try await render(source, edit: edit, to: cut)

        let asset = AVURLAsset(url: cut)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ComposerError.noSegments }
        let size = try await track.load(.naturalSize)
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.renderSize = size

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true  // lay out top-left like the editor; AVFoundation renders bottom-left
        let video = CALayer()
        video.frame = parent.frame
        if styling.backdrop != .none {
            parent.addSublayer(backdropLayer(styling.backdrop, size: size))
            let inset = size.width * 0.06
            video.frame = parent.frame.insetBy(dx: inset, dy: inset * size.height / size.width)
            video.cornerRadius = size.width * 0.012
            video.masksToBounds = true
            let shadow = CALayer()
            shadow.frame = video.frame
            shadow.cornerRadius = video.cornerRadius
            shadow.backgroundColor = CGColor(gray: 0, alpha: 1)
            shadow.shadowOpacity = 0.35
            shadow.shadowRadius = size.width * 0.02
            shadow.shadowOffset = CGSize(width: 0, height: size.width * 0.008)
            parent.addSublayer(shadow)
        }
        parent.addSublayer(video)

        let accent = cgColor(styling.accent)
        for overlay in styling.overlays {
            // Overlays are placed relative to the recorded screen, which moves when a backdrop insets it.
            let frame = CGRect(
                x: video.frame.minX + overlay.rect.minX * video.frame.width,
                y: video.frame.minY + overlay.rect.minY * video.frame.height,
                width: overlay.rect.width * video.frame.width,
                height: overlay.rect.height * video.frame.height
            )
            let layer = overlayLayer(overlay, frame: frame, accent: accent, scale: size.width / 1920)
            show(layer, from: overlay.start, to: overlay.end)
            parent.addSublayer(layer)
        }

        if styling.captions != .none, let transcript {
            for cue in captionCues(transcript, edit: edit, sourceDuration: sourceDuration) {
                let layer = captionLayer(cue.text, style: styling.captions, accent: accent, frame: parent.frame, scale: size.width / 1920)
                show(layer, from: cue.start, to: cue.end)
                parent.addSublayer(layer)
            }
        }

        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw ComposerError.exportUnavailable }
        export.videoComposition = composition
        try await export.export(to: destination, as: .mp4)
        return duration
    }

    private static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func backdropLayer(_ backdrop: Backdrop, size: CGSize) -> CALayer {
        let layer = CAGradientLayer()
        layer.frame = CGRect(origin: .zero, size: size)
        switch backdrop {
        case .gradient:
            layer.colors = [cgColor(0xFDE2CE), cgColor(0xF3B48E), cgColor(0xE2703A)]
            layer.startPoint = CGPoint(x: 0, y: 0)
            layer.endPoint = CGPoint(x: 1, y: 1)
        default:
            layer.colors = [cgColor(0x2A2421), cgColor(0x1C1815)]
        }
        return layer
    }

    private static func overlayLayer(_ overlay: Overlay, frame: CGRect, accent: CGColor, scale: CGFloat) -> CALayer {
        switch overlay.kind {
        case .box:
            let layer = CALayer()
            layer.frame = frame
            layer.borderColor = accent
            layer.borderWidth = 6 * scale
            layer.cornerRadius = 10 * scale
            return layer
        case .arrow:
            let layer = CAShapeLayer()
            layer.frame = frame
            let path = CGMutablePath()
            let start = CGPoint(x: 0, y: frame.height)
            let end = CGPoint(x: frame.width, y: 0)
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = 34 * scale
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7), y: end.y - head * sin(angle - .pi / 7)))
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7), y: end.y - head * sin(angle + .pi / 7)))
            layer.path = path
            layer.strokeColor = accent
            layer.fillColor = nil
            layer.lineWidth = 8 * scale
            layer.lineCap = .round
            layer.lineJoin = .round
            return layer
        case .text:
            let background = CALayer()
            background.frame = frame
            background.backgroundColor = CGColor(gray: 1, alpha: 0.94)
            background.cornerRadius = 12 * scale
            let fontSize = min(40 * scale, frame.height * 0.5)
            let text = textLayer(overlay.text, size: fontSize, color: NSColor(white: 0.1, alpha: 1))
            text.frame = CGRect(x: 0, y: (frame.height - fontSize * 1.25) / 2, width: frame.width, height: fontSize * 1.3)
            background.addSublayer(text)
            return background
        }
    }

    private static func captionLayer(_ text: String, style: CaptionStyle, accent: CGColor, frame: CGRect, scale: CGFloat) -> CALayer {
        let fontSize = 44 * scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let width = min(frame.width * 0.8, (text as NSString).size(withAttributes: [.font: font]).width + 48 * scale)
        let height = fontSize * 1.6
        let pill = CALayer()
        pill.frame = CGRect(x: frame.midX - width / 2, y: frame.maxY - height - frame.height * 0.06, width: width, height: height)
        pill.cornerRadius = height / 2
        pill.backgroundColor = style == .light ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.62)
        let label = textLayer(text, size: fontSize, color: style == .light ? NSColor(white: 0.1, alpha: 1) : .white)
        label.frame = CGRect(x: 0, y: (height - fontSize * 1.25) / 2, width: width, height: fontSize * 1.3)
        pill.addSublayer(label)
        return pill
    }

    /// Centered single-line text, drawn into a bitmap: text layers often come out blank in an export's
    /// animation tool, while image contents always render.
    private static func textLayer(_ text: String, size: CGFloat, color: NSColor) -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .center
        layer.contentsScale = 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        let bounds = attributed.size()
        let pixels = CGSize(width: ceil(bounds.width * 2), height: ceil(bounds.height * 2))
        guard pixels.width > 0, pixels.height > 0,
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return layer }
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(in: CGRect(origin: .zero, size: bounds))
        NSGraphicsContext.restoreGraphicsState()
        layer.contents = context.makeImage()
        return layer
    }

    /// Hidden outside `start...end`, on the exported timeline.
    private static func show(_ layer: CALayer, from start: Double, to end: Double) {
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1]
        animation.keyTimes = [0, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + max(start, 0.001)
        animation.duration = max(0.1, end - start)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .removed
        layer.add(animation, forKey: "visible")
    }

    /// Caption cues on the edited timeline, a few words each.
    static func captionCues(_ transcript: Transcript, edit: Edit, sourceDuration: Double) -> [(start: Double, end: Double, text: String)] {
        let words = transcript.words.compactMap { word -> TranscriptWord? in
            guard let start = edit.editedTime(forSourceTime: word.start, duration: sourceDuration) else { return nil }
            return TranscriptWord(text: word.text, start: start, end: start + (word.end - word.start))
        }
        var cues: [(Double, Double, String)] = []
        var index = 0
        while index < words.count {
            let slice = Array(words[index..<min(index + 6, words.count)])
            cues.append((slice.first!.start, slice.last!.end, slice.map(\.text).joined(separator: " ")))
            index += slice.count
        }
        return cues
    }
}
