import AVFoundation
import AppKit
import SwiftUI

enum BubbleShape: String, CaseIterable, Identifiable {
    case circle, squircle, portrait, landscape
    var id: Self { self }
    var label: String {
        switch self {
        case .circle: "Rond"
        case .squircle: "Squircle"
        case .portrait: "Portrait"
        case .landscape: "Paysage"
        }
    }
    /// Width / height.
    var aspect: CGFloat {
        switch self {
        case .circle, .squircle: 1
        case .portrait: 3 / 4
        case .landscape: 16 / 9
        }
    }
}

enum BubbleSize: CGFloat, CaseIterable, Identifiable {
    case small = 140, medium = 200, large = 280
    var id: Self { self }
    var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }
}

/// The camera, live, in a floating window. It is recorded along with the screen, like in Loom.
/// Drag it anywhere; on release it is thrown toward the nearest screen corner.
@MainActor
final class CameraBubbleController {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private lazy var runner = SessionRunner(session: session)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var shape: BubbleShape = .squircle
    private(set) var size: BubbleSize = .medium
    private var cameraID: String?

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func show(cameraID: String?, shape: BubbleShape, size: BubbleSize) {
        self.shape = shape
        self.size = size
        configureSession(cameraID: cameraID)
        let panel = panel ?? makePanel()
        self.panel = panel
        applyShape(animated: false)
        if !panel.isVisible { placeInCorner(panel, animated: false) }
        panel.orderFrontRegardless()
        if !session.isRunning { runner.start() }
    }

    func hide() {
        panel?.orderOut(nil)
        if session.isRunning { runner.stop() }
    }

    func update(shape: BubbleShape, size: BubbleSize) {
        self.shape = shape
        self.size = size
        applyShape(animated: true)
    }

    // MARK: Setup

    private func configureSession(cameraID: String?) {
        guard cameraID != self.cameraID || session.inputs.isEmpty else { return }
        self.cameraID = cameraID
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.sessionPreset = .high
        let device = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
    }

    private func makePanel() -> NSPanel {
        let panel = BubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: size.rawValue, height: size.rawValue),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.onDragEnded = { [weak self, weak panel] velocity in
            guard let self, let panel else { return }
            self.throwToCorner(panel, velocity: velocity)
        }

        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        // Mirror like a mirror: people expect to see themselves the way FaceTime shows them.
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer?.addSublayer(preview)
        view.layer?.masksToBounds = true
        // A fine bright rim, like light catching the edge of a glass.
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        view.layer?.borderWidth = 1.5
        previewLayer = preview
        panel.contentView = view
        return panel
    }

    private func applyShape(animated: Bool) {
        guard let panel, let view = panel.contentView else { return }
        let height = size.rawValue / max(shape.aspect, 1)
        let width = height * shape.aspect
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true, animate: animated)
        view.frame = NSRect(origin: .zero, size: frame.size)
        previewLayer?.frame = view.bounds
        let radius: CGFloat = switch shape {
        case .circle: min(width, height) / 2
        case .squircle: min(width, height) * Theme.Radius.bubbleSquircle
        case .portrait, .landscape: 22
        }
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        panel.invalidateShadow()
    }

    // MARK: Placement

    private static let margin: CGFloat = 24

    private func corners(for panel: NSWindow) -> [NSPoint] {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return [] }
        let size = panel.frame.size
        let m = Self.margin
        return [
            NSPoint(x: visible.minX + m, y: visible.minY + m),
            NSPoint(x: visible.maxX - size.width - m, y: visible.minY + m),
            NSPoint(x: visible.minX + m, y: visible.maxY - size.height - m),
            NSPoint(x: visible.maxX - size.width - m, y: visible.maxY - size.height - m),
        ]
    }

    private func placeInCorner(_ panel: NSWindow, animated: Bool) {
        guard let corner = corners(for: panel).first else { return }
        panel.setFrameOrigin(corner)
    }

    /// Projects the release velocity forward (scroll-like deceleration) and snaps to the corner nearest that point.
    private func throwToCorner(_ panel: NSWindow, velocity: CGVector) {
        let rate = 0.998
        func project(_ v: CGFloat) -> CGFloat { v / 1000 * rate / (1 - rate) }
        let projected = NSPoint(x: panel.frame.origin.x + project(velocity.dx), y: panel.frame.origin.y + project(velocity.dy))
        guard let target = corners(for: panel).min(by: { hypot($0.x - projected.x, $0.y - projected.y) < hypot($1.x - projected.x, $1.y - projected.y) }) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrameOrigin(target)
        }
    }
}

/// A borderless panel dragged 1:1 from wherever it was grabbed, reporting its release velocity.
final class BubblePanel: NSPanel {
    var onDragEnded: ((CGVector) -> Void)?
    private var grabOffset = NSPoint.zero
    private var history: [(point: NSPoint, time: TimeInterval)] = []

    override var canBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
        history = [(mouse, event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
        history.append((mouse, event.timestamp))
        if history.count > 6 { history.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
        guard let first = history.first, let last = history.last, last.time > first.time else {
            onDragEnded?(.zero)
            return
        }
        let dt = last.time - first.time
        onDragEnded?(CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt))
    }
}

/// Starts and stops the capture session off the main thread, as AVFoundation asks.
/// `startRunning` blocks for a moment; a serial queue keeps start and stop in order.
nonisolated final class SessionRunner: @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "app.reel.mac.camera")

    init(session: AVCaptureSession) { self.session = session }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }
}
