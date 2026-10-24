import AVFoundation
import AppKit
import Observation
import ReelKit
import UserNotifications
import os

private let log = Logger(subsystem: "app.reel.mac", category: "App")

enum SourceKind: String, CaseIterable, Identifiable {
    case screen, window, region, camera
    var id: Self { self }
    var label: String {
        switch self {
        case .screen: "Plein écran"
        case .window: "Fenêtre"
        case .region: "Zone"
        case .camera: "Caméra"
        }
    }
    var symbol: String {
        switch self {
        case .screen: "display"
        case .window: "macwindow"
        case .region: "rectangle.dashed"
        case .camera: "person.crop.square"
        }
    }
}

/// What happens after Stop, step by step, so the panel can show progress.
enum AfterRecording: Equatable {
    case idle
    case assembling
    case transcribing
    case uploading(Double)
    case done(URL?)
    case failed(String)
}

/// The app's state: recording options, the live recording, and the steps that follow it.
@Observable
final class AppModel {
    // Options
    var source: SourceKind = .screen
    var showsCamera = true
    var cameraID: String? = AVCaptureDevice.default(for: .video)?.uniqueID
    var microphoneID: String? = MicrophoneDevice.systemDefaultID
    var capturesSystemAudio = true
    var doNotDisturb = true
    var hidesDesktop = true
    var quality: CaptureQuality = .p1080
    var highlightsClicks = true
    var region: CGRect?
    var windowID: CGWindowID?

    // Live state
    private(set) var recorderState: Recorder.State = .idle
    private(set) var countdown: Int?
    private(set) var after: AfterRecording = .idle
    private(set) var lastError: String?

    let library = Library()
    private var recorder: Recorder?
    private var currentItem: VideoItem?

    var isBusy: Bool { recorderState != .idle || countdown != nil }

    var recordedDuration: Double { recorder?.recordedDuration ?? 0 }

    // MARK: Recording

    func startRecording(excludingWindows excluded: [CGWindowID] = []) async {
        guard !isBusy else { return }
        lastError = nil
        after = .idle
        for value in [3, 2, 1] {
            countdown = value
            try? await Task.sleep(for: .seconds(1))
        }
        countdown = nil

        let item = VideoItem(title: VideoItem.defaultTitle(for: .now), duration: 0)
        let recorder = Recorder(workingDirectory: library.workingDirectory(for: item.id))
        do {
            try await recorder.start(CaptureOptions(
                source: captureSource(),
                quality: quality,
                capturesSystemAudio: capturesSystemAudio,
                microphoneID: microphoneID,
                showsMouseClicks: highlightsClicks,
                excludedWindowIDs: excluded,
                hidesNotifications: doNotDisturb,
                hidesDesktopIcons: hidesDesktop
            ))
            self.recorder = recorder
            currentItem = item
            recorderState = .recording
        } catch {
            lastError = error.localizedDescription
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePause() async {
        guard let recorder else { return }
        do {
            if recorder.state == .recording { try await recorder.pause() } else { try recorder.resume() }
            recorderState = recorder.state
        } catch { lastError = error.localizedDescription }
    }

    /// Live Rewind: drop the last few seconds and keep going.
    func rewind(seconds: Double = 5) async {
        do { try await recorder?.rewind(by: seconds) } catch { lastError = error.localizedDescription }
    }

    func cancelRecording() async {
        guard let recorder, let item = currentItem else { return }
        _ = try? await recorder.stop()
        try? FileManager.default.removeItem(at: library.folder(for: item.id))
        self.recorder = nil
        currentItem = nil
        recorderState = .idle
    }

    func stopRecording() async {
        guard let recorder, var item = currentItem else { return }
        self.recorder = nil
        currentItem = nil
        recorderState = .idle
        do {
            after = .assembling
            let segments = try await recorder.stop()
            let videoURL = library.videoURL(for: item.id)
            item.duration = try await Composer.stitch(segments, to: videoURL)
            library.discardSegments(for: item.id)
            try library.save(item)
            let thumbnail = try? await Thumbnails.jpeg(from: videoURL, at: min(1, item.duration / 2))
            if let thumbnail { try? thumbnail.write(to: library.folder(for: item.id).appendingPathComponent("thumbnail.jpg")) }

            after = .transcribing
            let transcript = try? await Transcriber.transcribe(videoURL)
            if let transcript {
                try? JSONEncoder().encode(transcript).write(to: library.folder(for: item.id).appendingPathComponent("transcript.json"))
            }

            guard let account = CloudAccount.load() else {
                after = .done(nil)
                NSWorkspace.shared.activateFileViewerSelecting([videoURL])
                return
            }
            after = .uploading(0)
            var metadata = ShareMetadata(title: item.title, duration: item.duration)
            if let transcript { metadata.captions = Captions.webVTT(from: transcript, duration: item.duration) }
            let client = CloudClient(account: account)
            let uploaded = try await client.upload(videoURL, metadata: metadata) { value in
                Task { @MainActor [weak self] in self?.after = .uploading(value) }
            }
            if let thumbnail { try? await client.uploadThumbnail(thumbnail, videoID: uploaded.id) }
            item.shareURL = uploaded.url
            try library.save(item)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uploaded.url.absoluteString, forType: .string)
            after = .done(uploaded.url)
            await Notifier.linkCopied(title: item.title)
        } catch {
            after = .failed(error.localizedDescription)
            log.error("After recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies an existing video into the library, then makes its thumbnail and transcript.
    @discardableResult
    func importVideo(from source: URL) async throws -> VideoItem {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        var item = VideoItem(title: source.deletingPathExtension().lastPathComponent, duration: duration)
        try FileManager.default.createDirectory(at: library.folder(for: item.id), withIntermediateDirectories: true)
        let videoURL = library.videoURL(for: item.id)
        if source.pathExtension.lowercased() == "mp4" {
            try FileManager.default.copyItem(at: source, to: videoURL)
        } else {
            item.duration = try await Composer.stitch([Segment(url: source)], to: videoURL)
        }
        try library.save(item)
        if let thumbnail = try? await Thumbnails.jpeg(from: videoURL, at: min(1, duration / 2)) {
            try? thumbnail.write(to: library.folder(for: item.id).appendingPathComponent("thumbnail.jpg"))
        }
        if let transcript = try? await Transcriber.transcribe(videoURL) {
            try? JSONEncoder().encode(transcript).write(to: library.folder(for: item.id).appendingPathComponent("transcript.json"))
        }
        return item
    }

    private func captureSource() throws -> CaptureSource {
        let display = NSScreen.main?.displayID ?? CGMainDisplayID()
        switch source {
        case .screen, .camera: return .display(display)
        case .region: return .region(display, region ?? NSScreen.main.map { CGRect(origin: .zero, size: $0.frame.size) } ?? .zero)
        case .window:
            guard let windowID else { throw RecorderError.sourceNotFound }
            return .window(windowID)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum Notifier {
    static func linkCopied(title: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lien copié"
        content.body = "« \(title) » est prête à coller."
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
