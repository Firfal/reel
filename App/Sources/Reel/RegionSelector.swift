import AppKit

/// A dimmed full-screen overlay where the user drags out the area to record.
/// Returns the rect in display points with a top-left origin, as ScreenCaptureKit expects, or nil on Escape.
@MainActor
final class RegionSelector {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func select(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.sharingType = DemoMode.isOn ? .readOnly : .none
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in self?.finish(rect, screenHeight: screen.frame.height) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate()
            NSCursor.crosshair.push()
            self.window = window
        }
    }

    private func finish(_ rect: NSRect?, screenHeight: CGFloat) {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        let flipped = rect.map { CGRect(x: $0.minX, y: screenHeight - $0.maxY, width: $0.width, height: $0.height) }
        continuation?.resume(returning: flipped)
        continuation = nil
    }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }  // Escape
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let current, current.width > 40, current.height > 40 else {
            self.current = nil
            needsDisplay = true
            return
        }
        // Even sizes keep the encoder happy.
        let rect = NSRect(x: current.minX.rounded(), y: current.minY.rounded(),
                          width: (current.width / 2).rounded() * 2, height: (current.height / 2).rounded() * 2)
        onFinish?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let current else {
            let hint = "Fais glisser pour choisir la zone à enregistrer · Échap pour annuler" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        NSColor.clear.setFill()
        current.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: current.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()
        let label = "\(Int(current.width)) × \(Int(current.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        let badge = NSRect(x: current.midX - size.width / 2 - 8, y: current.minY - size.height - 14, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        label.draw(at: NSPoint(x: badge.minX + 8, y: badge.minY + 3), withAttributes: attributes)
    }
}
