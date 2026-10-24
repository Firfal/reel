import AVFoundation
import AppKit
import CoreGraphics
import ReelKit

/// End-to-end check of the recording engine, run with `open Reel.app --args --selftest <report.json>`.
/// Records the main display, pauses, resumes, rewinds, stitches, then writes a JSON report and quits.
/// Expected duration: 2 + 2 - 1 + 1 = 4 seconds.
enum SelfTest {
    static var reportPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--selftest"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `--transcribe <video> <report.json>`: transcribes a file on-device and writes the words.
    static var transcribeArguments: (video: String, report: String)? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--transcribe"), arguments.indices.contains(index + 2) else { return nil }
        return (arguments[index + 1], arguments[index + 2])
    }

    static func transcribe(video: String, reportPath: String) async {
        var report: [String: Any] = [:]
        let started = Date()
        do {
            let transcript = try await Transcriber.transcribe(URL(filePath: video), locale: Locale(identifier: "fr_FR"))
            report["locale"] = transcript.locale
            report["text"] = transcript.text
            report["words"] = transcript.words.prefix(8).map { "\($0.text)@\(String(format: "%.2f", $0.start))" }
            report["ok"] = !transcript.words.isEmpty
        } catch {
            report["error"] = String(describing: error)
            report["ok"] = false
        }
        report["seconds"] = Date().timeIntervalSince(started)
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: reportPath, contents: data)
        NSApplication.shared.terminate(nil)
    }

    static func run(reportPath: String) async {
        var report: [String: Any] = [
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "cameraPermission": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            "microphonePermission": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        ]
        do {
            let library = Library()
            let item = VideoItem(title: "Auto-test", duration: 0)
            let recorder = Recorder(workingDirectory: library.workingDirectory(for: item.id))
            let micAllowed = report["microphonePermission"] as? Bool == true
            try await recorder.start(CaptureOptions(
                source: .display(CGMainDisplayID()),
                quality: .p1080,
                microphoneID: micAllowed ? MicrophoneDevice.systemDefaultID : nil
            ))
            try await Task.sleep(for: .seconds(2))
            try await recorder.pause()
            try await Task.sleep(for: .seconds(1))
            try recorder.resume()
            try await Task.sleep(for: .seconds(2))
            try await recorder.rewind(by: 1)
            try await Task.sleep(for: .seconds(1))
            let segments = try await recorder.stop()
            let duration = try await Composer.stitch(segments, to: library.videoURL(for: item.id))
            var saved = item
            saved.duration = duration
            try library.save(saved)

            let asset = AVURLAsset(url: library.videoURL(for: item.id))
            let tracks = try await asset.load(.tracks)
            var trackInfo: [String] = []
            for track in tracks {
                let size = try await track.load(.naturalSize)
                trackInfo.append("\(track.mediaType.rawValue) \(Int(size.width))x\(Int(size.height))")
            }
            report["segments"] = segments.map { ["file": $0.url.lastPathComponent, "trimTail": $0.trimTail] }
            report["duration"] = duration
            report["tracks"] = trackInfo
            report["video"] = library.videoURL(for: item.id).path
            report["ok"] = abs(duration - 4) < 1.0  // each segment cut adds ~0.2 s of capture latency
        } catch {
            report["error"] = error.localizedDescription
            report["ok"] = false
        }
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: reportPath, contents: data)
        NSApplication.shared.terminate(nil)
    }
}
