import AVFoundation
import Observation
import Speech

/// Live dictation from the microphone with SpeechAnalyzer, on-device.
@MainActor
@Observable
public final class Dictation {
    public private(set) var isListening = false
    public private(set) var partial = ""
    private var finalText: [String] = []
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    public init() {}

    public func start() async {
        guard !isListening, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try? await request.downloadAndInstall() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        finalText = []
        partial = ""

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { self?.finalText.append(text); self?.partial = "" } else { self?.partial = text }
                }
            } catch {}
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = format.sampleRate / inputFormat.sampleRate
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1) else { return }
            var consumed = false
            converter.convert(to: converted, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        do {
            try engine.start()
            try await analyzer.start(inputSequence: stream)
            isListening = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    /// Stops listening and returns everything said.
    public func stop() async -> String {
        guard isListening else { return "" }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        isListening = false
        let text = (finalText + [partial]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        partial = ""
        return text
    }
}
