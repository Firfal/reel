import AVFoundation
import AppKit
import CoreGraphics
import ReelKit
import Synchronization

nonisolated final class ProgressLog: Sendable {
    private let storage = Mutex<[Double]>([])
    func add(_ value: Double) { storage.withLock { $0.append(value) } }
    var values: [Double] { storage.withLock { $0 } }
}

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

    /// `--import-cloud <file> <report.json>`: reads "url\ntoken" from a private file, saves it to the Keychain
    /// as this app (so later reads never prompt), then deletes the file.
    static var importArguments: (file: String, report: String)? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--import-cloud"), arguments.indices.contains(index + 2) else { return nil }
        return (arguments[index + 1], arguments[index + 2])
    }

    static func importCloud(file: String, reportPath: String) async {
        var report: [String: Any] = [:]
        do {
            let contents = try String(contentsOfFile: file, encoding: .utf8)
            // Delete now: `finish` quits the process, so a deferred removal would never run.
            try? FileManager.default.removeItem(atPath: file)
            let lines = contents.split(separator: "\n").map(String.init)
            guard lines.count >= 2, let url = URL(string: lines[0]) else { throw CloudError.server(status: 0, message: "bad import file") }
            try CloudAccount(serverURL: url, ownerToken: lines[1]).save()
            let usage = try await CloudClient(account: CloudAccount.load()!).usage()
            report["storageBytes"] = usage.storageBytes
            report["ok"] = true
        } catch {
            report["error"] = String(describing: error)
            report["ok"] = false
        }
        finish(report, at: reportPath)
    }

    /// `--share <video> <report.json>`: uploads a file to the sharing server, checks the link, then deletes it.
    static var shareArguments: (video: String, report: String)? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--share"), arguments.indices.contains(index + 2) else { return nil }
        return (arguments[index + 1], arguments[index + 2])
    }

    static func share(video: String, reportPath: String) async {
        var report: [String: Any] = [:]
        do {
            guard let account = CloudAccount.load() else { throw CloudError.server(status: 0, message: "no account") }
            let client = CloudClient(account: account)
            var metadata = ShareMetadata(title: "Auto-test d'envoi", duration: 8)
            metadata.chapters = [.init(time: 0, title: "Intro")]
            let progressLog = ProgressLog()
            let uploaded = try await client.upload(URL(filePath: video), metadata: metadata) { progressLog.add($0) }
            let (_, response) = try await URLSession.shared.data(from: uploaded.url)
            report["url"] = uploaded.url.absoluteString
            report["pageStatus"] = (response as? HTTPURLResponse)?.statusCode
            report["progress"] = progressLog.values
            try await client.delete(videoID: uploaded.id)
            report["ok"] = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            report["error"] = String(describing: error)
            report["ok"] = false
        }
        finish(report, at: reportPath)
    }

    private static func finish(_ report: [String: Any], at path: String) {
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: path, contents: data)
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
