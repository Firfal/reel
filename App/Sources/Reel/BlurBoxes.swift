import AppKit

/// Frosted rectangles laid over sensitive parts of the screen while recording. They are real windows, so the
/// recording captures the blur; drag to move, drag the bottom-right corner to resize, double-click to remove.
@MainActor
final class BlurBoxes {
    private var windows: [NSWindow] = []

    func add() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 320, height: 120)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        let window = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 60, height: 30)

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        let removable = RemovableView(frame: .zero)
        removable.onDoubleClick = { [weak self, weak window] in
            guard let window else { return }
            window.orderOut(nil)
            self?.windows.removeAll { $0 === window }
        }
        removable.addSubview(blur)
        blur.frame = removable.bounds
        blur.autoresizingMask = [.width, .height]
        window.contentView = removable
        window.orderFrontRegardless()
        windows.append(window)
    }

    func removeAll() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class RemovableView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
