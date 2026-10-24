import AVFoundation
import Foundation
import ScreenCaptureKit
import Synchronization
import os

private let log = Logger(subsystem: "app.reel.mac", category: "Recorder")

public enum RecorderError: LocalizedError {
    case sourceNotFound
    case alreadyRecording
    case notRecording
    case recordingOutputRejected
    case segmentFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound: "L'écran ou la fenêtre à enregistrer est introuvable."
        case .alreadyRecording: "Un enregistrement est déjà en cours."
        case .notRecording: "Aucun enregistrement en cours."
        case .recordingOutputRejected: "macOS a refusé de démarrer l'enregistrement."
        case .segmentFailed(let error): "L'enregistrement a échoué : \(error.localizedDescription)"
        }
    }
}

/// Records the screen with ScreenCaptureKit into segment files.
///
/// Pause and Live Rewind close the current segment; `stop()` returns every segment, ready for `Composer`.
@MainActor
public final class Recorder {
    public enum State: Equatable { case idle, recording, paused }

    public private(set) var state: State = .idle
    public private(set) var segments: [Segment] = []

    private var stream: SCStream?
    private var current: (output: SCRecordingOutput, observer: SegmentObserver, url: URL, startedAt: Date)?
    private var segmentDurations: [Double] = []
    private var segmentCounter = 0
    private let workingDirectory: URL

    /// `workingDirectory` receives the segment files. It is created if needed.
    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    public func start(_ options: CaptureOptions) async throws {
        guard state == .idle else { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, sourceSize) = try Self.filter(for: options, in: content)
        let configuration = Self.configuration(for: options, sourceSize: sourceSize)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream
        segments = []
        segmentDurations = []
        segmentCounter = 0
        try openSegment()
        try await stream.startCapture()
        state = .recording
        log.info("Recording started at \(Int(configuration.width))x\(Int(configuration.height))")
    }

    public func pause() async throws {
        guard state == .recording else { throw RecorderError.notRecording }
        try await closeSegment()
        state = .paused
    }

    public func resume() throws {
        guard state == .paused else { throw RecorderError.notRecording }
        try openSegment()
        state = .recording
    }

    /// Drops the last `seconds` of the recording and keeps recording (Live Rewind).
    public func rewind(by seconds: Double) async throws {
        guard state != .idle else { throw RecorderError.notRecording }
        let wasRecording = state == .recording
        if wasRecording { try await closeSegment() }
        segments = segments.rewound(by: seconds, durations: segmentDurations)
        if wasRecording { try openSegment() }
    }

    /// Seconds recorded so far, after rewinds.
    public var recordedDuration: Double {
        let closed = zip(segments, segmentDurations).reduce(0) { $0 + max(0, $1.1 - $1.0.trimTail) }
        let running = current.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        return closed + running
    }

    /// Stops capture and returns the non-empty segments, in order.
    public func stop() async throws -> [Segment] {
        guard state != .idle, let stream else { throw RecorderError.notRecording }
        if state == .recording { try await closeSegment() }
        try? await stream.stopCapture()
        self.stream = nil
        state = .idle
        return zip(segments, segmentDurations)
            .filter { $0.1 - $0.0.trimTail > 0.05 }
            .map(\.0)
    }

    // MARK: Segments

    private func openSegment() throws {
        guard let stream else { throw RecorderError.notRecording }
        segmentCounter += 1
        let url = workingDirectory.appendingPathComponent("segment-\(segmentCounter).mp4")
        try? FileManager.default.removeItem(at: url)
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        configuration.videoCodecType = .h264
        let observer = SegmentObserver()
        let output = SCRecordingOutput(configuration: configuration, delegate: observer)
        do {
            try stream.addRecordingOutput(output)
        } catch {
            throw RecorderError.recordingOutputRejected
        }
        current = (output, observer, url, Date())
    }

    private func closeSegment() async throws {
        guard let stream, let current else { return }
        self.current = nil
        try stream.removeRecordingOutput(current.output)
        try await current.observer.finished()
        let duration = try await AVURLAsset(url: current.url).load(.duration).seconds
        segments.append(Segment(url: current.url))
        segmentDurations.append(duration.isFinite ? duration : 0)
    }

    // MARK: Configuration

    private static func filter(for options: CaptureOptions, in content: SCShareableContent) throws -> (SCContentFilter, CGSize) {
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let excluded = content.windows.filter { window in
            let bundleID = window.owningApplication?.bundleIdentifier
            if options.excludedWindowIDs.contains(window.windowID) { return true }
            if options.hidesNotifications, bundleID == "com.apple.notificationcenterui" { return true }
            if options.hidesDesktopIcons, bundleID == "com.apple.finder", window.windowLayer == desktopIconLevel { return true }
            return false
        }
        switch options.source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.sourceNotFound }
            return (SCContentFilter(display: display, excludingWindows: excluded), display.frame.size)
        case .region(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.sourceNotFound }
            return (SCContentFilter(display: display, excludingWindows: excluded), rect.size)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.sourceNotFound }
            return (SCContentFilter(desktopIndependentWindow: window), window.frame.size)
        }
    }

    private static func configuration(for options: CaptureOptions, sourceSize: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = options.outputSize(forSourceSize: sourceSize)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        if case .region(_, let rect) = options.source { configuration.sourceRect = rect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.showsCursor = options.showsCursor
        configuration.showMouseClicks = options.showsMouseClicks
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if let microphoneID = options.microphoneID {
            configuration.captureMicrophone = true
            if microphoneID != MicrophoneDevice.systemDefaultID {
                configuration.microphoneCaptureDeviceID = microphoneID
            }
        }
        configuration.queueDepth = 6
        return configuration
    }
}

/// Bridges `SCRecordingOutputDelegate` callbacks, which arrive on a ScreenCaptureKit queue, to `async`.
private final class SegmentObserver: NSObject, SCRecordingOutputDelegate, Sendable {
    private enum Outcome { case finished, failed(any Error) }
    private let state = Mutex<(outcome: Outcome?, waiter: CheckedContinuation<Void, any Error>?)>((nil, nil))

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        resolve(.failed(error))
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolve(.finished)
    }

    nonisolated func finished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = state.withLock { state -> Outcome? in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let outcome { Self.resume(continuation, with: outcome) }
        }
    }

    private nonisolated func resolve(_ outcome: Outcome) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiter = nil }
            return state.waiter
        }
        if let waiter { Self.resume(waiter, with: outcome) }
    }

    private nonisolated static func resume(_ continuation: CheckedContinuation<Void, any Error>, with outcome: Outcome) {
        switch outcome {
        case .finished: continuation.resume()
        case .failed(let error): continuation.resume(throwing: RecorderError.segmentFailed(error))
        }
    }
}
