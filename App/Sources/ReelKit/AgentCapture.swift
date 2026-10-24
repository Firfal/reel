import AppKit
import ScreenCaptureKit
import Vision

/// One thing the user did while recording for an agent.
public struct AgentEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case click, rightClick }

    public var time: Double
    public var kind: Kind
    /// Click position in screen points, origin top-left.
    public var x: Double
    public var y: Double
    public var app: String
    public var window: String?
    public var url: String?
    /// The text under or nearest to the click, read from the screen.
    public var target: String?
    /// File name of the cropped screenshot, in the video's folder.
    public var screenshot: String?
}

/// Watches clicks while a recording runs in agent mode, and describes each one from what is on screen.
/// Mouse clicks are observed with a global monitor, which needs no Accessibility permission; keystrokes are never read.
@MainActor
public final class AgentCapture {
    public private(set) var events: [AgentEvent] = []
    private var monitor: Any?
    private let folder: URL
    private let clock: () -> Double
    private var pending: [Task<Void, Never>] = []

    /// `clock` returns the current position in the recording, in seconds.
    public init(folder: URL, clock: @escaping () -> Double) {
        self.folder = folder
        self.clock = clock
    }

    public func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
    }

    /// Stops watching and waits for the last screenshots to be read.
    public func stop() async -> [AgentEvent] {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for task in pending { await task.value }
        pending = []
        return events.sorted { $0.time < $1.time }
    }

    private func record(_ event: NSEvent) {
        let time = clock()
        let point = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: point.x, y: screenHeight - point.y)
        let app = NSWorkspace.shared.frontmostApplication
        let index = events.count
        var entry = AgentEvent(
            time: time,
            kind: event.type == .rightMouseDown ? .rightClick : .click,
            x: topLeft.x.rounded(),
            y: topLeft.y.rounded(),
            app: app?.localizedName ?? "?",
            window: Self.windowTitle(at: topLeft),
            url: app?.bundleIdentifier.flatMap(BrowserURL.read(bundleID:))
        )
        entry.screenshot = "step-\(index + 1).png"
        events.append(entry)

        let file = folder.appendingPathComponent(entry.screenshot!)
        pending.append(Task { [weak self] in
            let target = await Self.capture(around: topLeft, to: file)
            self?.events[index].target = target
        })
    }

    // MARK: Screen reading

    /// Title of the topmost window under the point, from the window list (needs screen recording, which Reel has).
    private static func windowTitle(at point: CGPoint) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in windows where (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point)
            else { continue }
            let title = info[kCGWindowName as String] as? String
            return title?.isEmpty == false ? title : nil
        }
        return nil
    }

    /// Saves a crop around the click, marks the click, and returns the text nearest to it.
    @concurrent
    private static func capture(around point: CGPoint, to file: URL) async -> String? {
        let cropSize = CGSize(width: 520, height: 300)
        let rect = CGRect(x: point.x - cropSize.width / 2, y: point.y - cropSize.height / 2, width: cropSize.width, height: cropSize.height)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first
        else { return nil }
        let ownBundle = Bundle.main.bundleIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == ownBundle }, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: display.frame.size))
        configuration.sourceRect = local
        configuration.width = Int(local.width * 2)
        configuration.height = Int(local.height * 2)
        configuration.showsCursor = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }

        let clickInCrop = CGPoint(x: (point.x - display.frame.minX - local.minX) / local.width, y: (point.y - display.frame.minY - local.minY) / local.height)
        if let marked = mark(image, at: clickInCrop) {
            try? NSBitmapImageRep(cgImage: marked).representation(using: .png, properties: [:])?.write(to: file)
        }
        return nearestText(in: image, to: clickInCrop)
    }

    /// Draws a ring where the click happened, so the agent sees exactly what was clicked.
    nonisolated private static func mark(_ image: CGImage, at unit: CGPoint) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let center = CGPoint(x: unit.x * CGFloat(width), y: (1 - unit.y) * CGFloat(height))
        context.setStrokeColor(CGColor(srgbRed: 0.886, green: 0.439, blue: 0.227, alpha: 1))
        context.setLineWidth(5)
        context.strokeEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
        return context.makeImage()
    }

    /// On-device text recognition; returns the line whose box contains, or is closest to, the click.
    nonisolated private static func nearestText(in image: CGImage, to unit: CGPoint) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let click = CGPoint(x: unit.x, y: 1 - unit.y)  // Vision's origin is bottom-left
        let observations = request.results ?? []
        func distance(_ box: CGRect) -> CGFloat {
            if box.insetBy(dx: -0.01, dy: -0.02).contains(click) { return 0 }
            return hypot(max(box.minX - click.x, 0, click.x - box.maxX), max(box.minY - click.y, 0, click.y - box.maxY))
        }
        guard let best = observations.min(by: { distance($0.boundingBox) < distance($1.boundingBox) }),
              distance(best.boundingBox) < 0.12,
              let text = best.topCandidates(1).first?.string
        else { return nil }
        return text
    }
}

/// Reads the front tab's address in common browsers with Apple Events. macOS asks once per browser.
enum BrowserURL {
    private static let scripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
    ]

    @MainActor
    static func read(bundleID: String) -> String? {
        guard let source = scripts[bundleID], let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error).stringValue
        return result?.isEmpty == false ? result : nil
    }
}
