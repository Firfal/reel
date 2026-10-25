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
    /// True while a macOS window opened from the panel (video effects, mic modes) is on screen:
    /// clicks there must not close the panel, or the camera stops and macOS closes its window too.
    private var panelHeldOpen = false
    private var isSelectingRegion = false
    private var panelIdealSize: () -> NSSize = { NSSize(width: 340, height: 480) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bubble.onMove = { [weak self] frame in self?.teleprompter.place(next: frame) }
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
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.idle
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        registerHotKey()
        if !DemoMode.isOn {
            Task {
                let hasServer = await CloudAccount.current() != nil
                if OnboardingController.isDone || hasServer { requestCameraAndMicrophone() } else { onboarding.show() }
            }
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
            case "settings":
                let tab = arguments.firstIndex(of: "--tab").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
                settings.show(tab: tab)
            case "onboarding": onboarding.show()
            case "editor":
                if let video = arguments.dropFirst(index + 2).first, !video.hasPrefix("--") {
                    DemoMode.openItemID = try? await model.importVideo(from: URL(filePath: video)).id
                } else {
                    DemoMode.openItemID = model.library.items().first?.id
                }
                openLibrary()
            case "recording":
                bubble.show(cameraID: model.cameraID, shape: bubbleSettings.shape, size: bubbleSettings.size)
                controlBar.show(model: model, onStop: {}, onCancel: {}, onDraw: {})
                if notes.text.isEmpty { notes.text = "Bonjour, je vous montre la nouvelle page de réglages, puis l'export." }
                teleprompter.show(notes: notes, next: bubble.frame)
            default: break
            }
            try? await Task.sleep(for: .seconds(2))
            DemoMode.snapshotIfAsked()
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
        let size = panelIdealSize()
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        panelHeldOpen = false
        if model.cameraID != nil { bubble.show(cameraID: model.cameraID, shape: bubbleSettings.shape, size: bubbleSettings.size) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panelHeldOpen else { return }
                self.closePanel()
            }
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panelHeldOpen = false
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
        panel.onCancel = { [weak self] in self?.closePanel() }
        // Back in the panel after a macOS window: outside clicks close it again.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelHeldOpen = false }
        }
        let root = MenuPanel(model: model, bubble: bubbleSettings, notes: notes, onRecord: { [weak self] in
            Task { await self?.record() }
        }, onOpenLibrary: { [weak self] in
            self?.closePanel()
            self?.openLibrary()
        }, onOpenSettings: { [weak self] in
            self?.closePanel()
            self?.settings.show()
        }, onSystemWindow: { [weak self] in
            self?.panelHeldOpen = true
        }, onHeightChange: { [weak panel] height in
            panel?.resize(toHeight: height)
        })
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
        let hosting = NSHostingController(rootView: root)
        // The panel follows the content's height itself, keeping its top under the menu bar.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panelIdealSize = { NSSize(width: 340, height: hosting.sizeThatFits(in: NSSize(width: 340, height: 2000)).height) }
        return panel
    }

    // MARK: Recording

    private func record() async {
        guard !isSelectingRegion else { return }
        await notes.finishDictation()
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
            isSelectingRegion = true
            var rect: CGRect?
            if let screen = NSScreen.main { rect = await regionSelector.select(on: screen) }
            isSelectingRegion = false
            guard let rect else { return }
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
        teleprompter.show(notes: notes, model: model, next: bubble.frame)
        statusItem?.button?.image = StatusIcon.recording
        await model.startRecording()
        if !model.isBusy {
            tearDownRecordingUI()
            // The panel is where a failed start explains itself.
            if model.lastError != nil { openPanel() }
        }
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

    /// Without a main menu, ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z do nothing in text fields: the shortcuts live in the Edit menu.
    private func installEditMenu() {
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let app = NSMenu(title: "Reel")
        app.addItem(withTitle: "Fermer la fenêtre", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quitter Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menu = NSMenu()
        for submenu in [app, edit] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
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

    /// `--snapshot <folder> [--size WxH]`: draws every visible window into PNGs, then quits. Works with the screen locked.
    static func snapshotIfAsked() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return }
        let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        if let sizeIndex = arguments.firstIndex(of: "--size"), arguments.indices.contains(sizeIndex + 1) {
            let parts = arguments[sizeIndex + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: parts[0], height: parts[1])), display: true)
                }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var frames = ""
            for (number, window) in NSApp.windows.filter({ $0.isVisible && $0.frame.width > 60 }).enumerated() {
                frames += "window-\(number) \(type(of: window)) \(window.frame)\n"
                guard let view = window.contentView?.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("window-\(number).png"))
            }
            try? frames.write(to: folder.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

/// A borderless panel that can take keyboard focus, so its controls draw in their active colors.
/// A borderless window that takes keyboard focus, so overlays hear Escape.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Grows or shrinks downward, so the top edge stays where it is.
    func resize(toHeight height: CGFloat) {
        let height = height.rounded(.up)
        guard abs(frame.height - height) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }
}
