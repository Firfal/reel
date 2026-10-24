import AVFoundation
import Foundation
import Speech

/// A word with its position in the video, in seconds.
public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Codable, Sendable, Hashable {
    public var locale: String
    public var words: [TranscriptWord]

    public init(locale: String, words: [TranscriptWord]) {
        self.locale = locale
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

public enum TranscriberError: LocalizedError {
    case unsupportedLanguage(String)
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let identifier): "La transcription n'est pas disponible pour la langue \(identifier) sur ce Mac."
        case .noAudio: "La vidéo n'a pas de son à transcrire."
        }
    }
}

/// On-device transcription with Apple's SpeechAnalyzer. Nothing leaves the Mac.
public enum Transcriber {
    /// Transcribes the audio of `videoURL`, downloading the language model first if needed.
    @concurrent
    public static func transcribe(_ videoURL: URL, locale preferred: Locale = .current) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw TranscriberError.unsupportedLanguage(preferred.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audioURL = try await extractAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioFile = try AVAudioFile(forReading: audioURL)

        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(in: result.text))
            }
            return words
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let end = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await collector.value
        return Transcript(locale: locale.identifier, words: words)
    }

    /// Splits a result into words, each timed by the audio range of its runs.
    static func words(in text: AttributedString) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            let tokens = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            // A run can hold several words; spread its time range evenly across them.
            let start = range.start.seconds
            let step = range.duration.seconds / Double(tokens.count)
            for (index, token) in tokens.enumerated() {
                words.append(TranscriptWord(
                    text: token,
                    start: start + step * Double(index),
                    end: start + step * Double(index + 1)
                ))
            }
        }
        return words
    }

    private static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw TranscriberError.noAudio }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.noAudio
        }
        try await export.export(to: output, as: .m4a)
        return output
    }
}
