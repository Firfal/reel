import AppKit

/// A transparent full-screen layer to draw on while recording. It is recorded with the screen.
/// Strokes fade out a few seconds after the pen lifts, so the screen never stays cluttered.
@MainActor
final class DrawingOverlay {
    private var window: NSWindow?
    private(set) var isActive = false

    func toggle() {
        isActive ? deactivate() : activate()
    }

    func activate() {
        guard let screen = NSScreen.main else { return }
        let window = window ?? makeWindow(screen: screen)
        self.window = window
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        NSCursor.crosshair.push()
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        window?.ignoresMouseEvents = true
        NSCursor.pop()
        isActive = false
    }

    func close() {
        deactivate()
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onEscape = { [weak self] in self?.deactivate() }
        window.contentView = view
        return window
    }
}

private final class InkView: NSView {
    var onEscape: (() -> Void)?
    private struct Stroke { var path = NSBezierPath(); var endedAt: Date? }
    private var strokes: [Stroke] = []
    private var timer: Timer?
    private let ink = NSColor(srgbRed: 0.886, green: 0.439, blue: 0.227, alpha: 1)  // Theme.accent, light value
    private static let lifetime: TimeInterval = 3
    private static let fade: TimeInterval = 0.6

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } }

    override func mouseDown(with event: NSEvent) {
        var stroke = Stroke()
        stroke.path.lineWidth = 4
        stroke.path.lineCapStyle = .round
        stroke.path.lineJoinStyle = .round
        stroke.path.move(to: convert(event.locationInWindow, from: nil))
        strokes.append(stroke)
    }

    override func mouseDragged(with event: NSEvent) {
        strokes[strokes.count - 1].path.line(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        strokes[strokes.count - 1].endedAt = .now
        timer = timer ?? Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date.now
        strokes.removeAll { stroke in
            guard let ended = stroke.endedAt else { return false }
            return now.timeIntervalSince(ended) > Self.lifetime + Self.fade
        }
        if strokes.isEmpty { timer?.invalidate(); timer = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date.now
        for stroke in strokes {
            var alpha: CGFloat = 1
            if let ended = stroke.endedAt {
                let age = now.timeIntervalSince(ended) - Self.lifetime
                if age > 0 { alpha = max(0, 1 - age / Self.fade) }
            }
            ink.withAlphaComponent(alpha).setStroke()
            stroke.path.stroke()
        }
    }
}
