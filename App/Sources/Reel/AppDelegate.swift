import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ReelKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private let model = AppModel()
    private let bubbleSettings = BubbleSettings()
    private let bubble = CameraBubbleController()
    private let controlBar = ControlBarController()
    private let drawing = DrawingOverlay()
    private let regionSelector = RegionSelector()
    private let blurBoxes = BlurBoxes()
    private let notes = SpeakerNotes()
    private let teleprompter = TeleprompterController()
    private var library: LibraryWindowController?
    private let settings = SettingsWindowController()
    private let onboarding = OnboardingController()
    private var hotKey: EventHotKeyRef?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reportPath = SelfTest.reportPath {
            Task { await SelfTest.run(reportPath: reportPath) }
            return
        }
        if let arguments = SelfTest.importArguments {
            Task { await SelfTest.importCloud(file: arguments.file, reportPath: arguments.report) }
            return
        }
        if let arguments = SelfTest.importClaudeArguments {
            Task { await SelfTest.importClaude(file: arguments.file, reportPath: arguments.report) }
            return
        }
        if let arguments = SelfTest.shareArguments {
            Task { await SelfTest.share(video: arguments.video, reportPath: arguments.report) }
            return
        }
        if let arguments = SelfTest.transcribeArguments {
            Task { await SelfTest.transcribe(video: arguments.video, reportPath: arguments.report) }
            return
        }

        Theme.registerFonts()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.idle
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        registerHotKey()
        if !DemoMode.isOn {
            if OnboardingController.isDone || CloudAccount.load() != nil { requestCameraAndMicrophone() } else { onboarding.show() }
        }
        observeModel()
        runDemoIfAsked()
    }

    /// `--demo panel|library|recording`, or `--demo editor <video>` (imports the video first): opens one screen as-is, for screenshots during development.
    private func runDemoIfAsked() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo"), arguments.indices.contains(index + 1) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            switch arguments[index + 1] {
            case "panel": openPanel()
            case "library": openLibrary()
            case "settings": settings.show()
            case "onboarding": onboarding.show()
            case "editor":
                if let video = arguments.dropFirst(index + 2).first {
                    DemoMode.openItemID = try? await model.importVideo(from: URL(filePath: video)).id
                }
                openLibrary()
            case "recording":
                bubble.show(cameraID: model.cameraID, shape: bubbleSettings.shape, size: bubbleSettings.size)
                controlBar.show(model: model, onStop: {}, onCancel: {}, onDraw: {})
            default: break
            }
        }
    }

    // MARK: Panel

    @objc private func togglePanel() {
        if model.isBusy {
            Task { await stop() }
            return
        }
        if let panel, panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 480)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if model.cameraID != nil { bubble.show(cameraID: model.cameraID, shape: bubbleSettings.shape, size: bubbleSettings.size) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if !model.isBusy { bubble.hide() }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = DemoMode.isOn ? .readOnly : .none
        let root = MenuPanel(model: model, bubble: bubbleSettings, notes: notes, onRecord: { [weak self] in
            Task { await self?.record() }
        }, onOpenLibrary: { [weak self] in
            self?.closePanel()
            self?.openLibrary()
        }, onOpenSettings: { [weak self] in
            self?.closePanel()
            self?.settings.show()
        })
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    // MARK: Recording

    private func record() async {
        closePanel()
        guard CGPreflightScreenCaptureAccess() else {
            // Asks the first time; afterwards macOS only points to System Settings, which the panel offers too.
            CGRequestScreenCaptureAccess()
            model.needsScreenPermission = true
            openPanel()
            return
        }
        model.needsScreenPermission = false
        switch model.source {
        case .region:
            guard let screen = NSScreen.main, let rect = await regionSelector.select(on: screen) else { return }
            model.region = rect
        case .window:
            guard let id = Self.frontmostWindowID() else {
                model.source = .screen
                return
            }
            model.windowID = id
        case .camera, .screen:
            break
        }
        if model.cameraID != nil {
            let size: BubbleSize = model.source == .camera ? .large : bubbleSettings.size
            bubble.show(cameraID: model.cameraID, shape: bubbleSettings.shape, size: size)
        }
        controlBar.show(model: model, onStop: { [weak self] in Task { await self?.stop() } },
                        onCancel: { [weak self] in Task { await self?.cancel() } },
                        onDraw: { [weak self] in self?.drawing.toggle() },
                        onBlur: { [weak self] in self?.blurBoxes.add() })
        teleprompter.show(notes: notes, below: bubble.frame)
        statusItem?.button?.image = StatusIcon.recording
        await model.startRecording()
        if !model.isBusy { tearDownRecordingUI() }
    }

    private func stop() async {
        tearDownRecordingUI()
        await model.stopRecording()
    }

    private func cancel() async {
        tearDownRecordingUI()
        await model.cancelRecording()
    }

    private func tearDownRecordingUI() {
        controlBar.hide()
        drawing.close()
        blurBoxes.removeAll()
        teleprompter.hide()
        bubble.hide()
        statusItem?.button?.image = StatusIcon.idle
    }

    /// The front window of the app the user was in, ignoring Reel's own windows.
    private static func frontmostWindowID() -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let window = windows.first { info in
            (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID
        }
        return window?[kCGWindowNumber as String] as? CGWindowID
    }

    private func observeModel() {
        withObservationTracking {
            _ = bubbleSettings.shape
            _ = bubbleSettings.size
            _ = model.cameraID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.cameraID == nil {
                    self.bubble.hide()
                } else if self.panel?.isVisible == true {
                    self.bubble.show(cameraID: self.model.cameraID, shape: self.bubbleSettings.shape, size: self.bubbleSettings.size)
                }
                self.observeModel()
            }
        }
    }

    // MARK: Library

    private func openLibrary() {
        let controller = library ?? LibraryWindowController(model: model)
        library = controller
        controller.show()
    }

    // MARK: Hot key ⌥⇧R

    private func registerHotKey() {
        var handler: EventHandlerRef?
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated {
                if delegate.model.isBusy { Task { await delegate.stop() } } else { Task { await delegate.record() } }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5245_454C), id: 1)  // 'REEL'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// Camera and microphone ask once; macOS remembers the answer. Screen recording is checked only when
    /// a recording starts (see `record()`), so a launch never shows a prompt for a permission already given.
    private func requestCameraAndMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                }
            }
        } else if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
}

/// Menu bar icons: Halo's mark (a pill with its playhead) at rest, a filled dot while recording.
enum StatusIcon {
    static let idle = draw(recording: false)
    static let recording = draw(recording: true)

    private static func draw(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if recording {
                NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            } else {
                let track = NSBezierPath(roundedRect: NSRect(x: 2, y: 7.5, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5)
                track.fill()
                let head = NSBezierPath(ovalIn: NSRect(x: 8.5, y: 5, width: 8, height: 8))
                head.lineWidth = 1.6
                NSColor.white.setFill()
                head.fill()
                head.stroke()
            }
            return true
        }
        image.isTemplate = !recording
        return image
    }
}

/// Development screenshots: in `--demo`, Reel's own panels stay visible to screen capture.
enum DemoMode {
    static let isOn = CommandLine.arguments.contains("--demo")
    /// The library opens straight into this video's editor.
    static var openItemID: UUID?
}

/// A borderless panel that can take keyboard focus, so its controls draw in their active colors.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
