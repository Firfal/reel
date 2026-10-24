import AVFoundation
import Accelerate

/// Loudness over time, used to find silences and hesitations precisely.
/// Apple's transcriber drops « euh » from the text and folds that time, and nearby pauses, into the
/// neighboring word; the audio level tells where speech really is.
public struct AudioLevels: Sendable {
    /// Seconds per value.
    public let step: Double
    /// Loudness in dBFS, one value per `step`.
    public let decibels: [Float]

    public init(step: Double, decibels: [Float]) {
        self.step = step
        self.decibels = decibels
    }

    /// Reads the audio track of `url` at 16 kHz mono and measures it every `step` seconds.
    @concurrent
    public static func measure(_ url: URL, step: Double = 0.02) async throws -> AudioLevels {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return AudioLevels(step: step, decibels: []) }
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        let window = Int(sampleRate * step)
        var decibels: [Float] = []
        decibels.reserveCapacity(samples.count / max(window, 1))
        var index = 0
        while index + window <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + index, 1, &rms, vDSP_Length(window)) }
            decibels.append(20 * log10(max(rms, 1e-6)))
            index += window
        }
        return AudioLevels(step: step, decibels: decibels)
    }

    /// Level separating speech from background, placed between the noise floor and typical speech.
    public var speechThreshold: Float {
        guard !decibels.isEmpty else { return -40 }
        let sorted = decibels.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[sorted.count * 9 / 10]
        return floor + (speech - floor) * 0.3
    }

    /// Stretches where speech is present, at least `minimum` seconds long, merging gaps shorter than `bridge`.
    public func voicedRanges(in range: ClosedRange<Double>? = nil, minimum: Double = 0.06, bridge: Double = 0.08) -> [ClosedRange<Double>] {
        let threshold = speechThreshold
        let first = range.map { max(0, Int($0.lowerBound / step)) } ?? 0
        let last = range.map { min(decibels.count, Int($0.upperBound / step) + 1) } ?? decibels.count
        guard first < last else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var start: Int?
        for index in first..<last {
            let voiced = decibels[index] >= threshold
            if voiced, start == nil { start = index }
            if !voiced, let s = start {
                ranges.append(Double(s) * step...Double(index) * step)
                start = nil
            }
        }
        if let s = start { ranges.append(Double(s) * step...Double(last) * step) }
        var merged: [ClosedRange<Double>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound - previous.upperBound < bridge {
                merged[merged.count - 1] = previous.lowerBound...range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= minimum }
    }

    /// Linear gain that brings typical speech to `target` dBFS, never boosting more than `maxBoost` dB,
    /// and never pushing the loudest moment past -1 dBFS.
    public func normalizingGain(target: Float = -18, maxBoost: Float = 12) -> Double {
        let threshold = speechThreshold
        let speech = decibels.filter { $0 >= threshold }.sorted()
        guard !speech.isEmpty, let peak = decibels.max() else { return 1 }
        let typical = speech[speech.count / 2]
        let change = min(target - typical, maxBoost, -1 - peak)
        return Double(pow(10, change / 20))
    }

    /// Quiet stretches of at least `minimum` seconds, keeping `padding` of air next to the speech.
    public func silences(duration: Double, minimum: Double = 0.9, padding: Double = 0.2) -> [ClosedRange<Double>] {
        let voiced = voicedRanges()
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for range in voiced + [duration...duration] {
            if range.lowerBound - cursor >= minimum {
                let start = cursor == 0 ? 0 : cursor + padding
                let end = range.lowerBound == duration ? duration : range.lowerBound - padding
                if end > start { gaps.append(start...end) }
            }
            cursor = max(cursor, range.upperBound)
        }
        return gaps
    }
}

extension Cleanup {
    /// Hesitations found with the audio: inside a word that lasts much longer than it should, any extra burst
    /// of sound besides the word itself is cut, with the pause around it.
    public static func hesitations(in transcript: Transcript, levels: AudioLevels) -> [ClosedRange<Double>] {
        var cuts = fillerWords(in: transcript).map { $0.start...$0.end }
        for word in transcript.words {
            let letters = word.text.filter(\.isLetter).count
            let expected = max(0.25, Double(letters) * 0.085)
            guard word.end - word.start > expected * 1.8 else { continue }
            let islands = levels.voicedRanges(in: (word.start - 0.03)...(word.end + 0.03), minimum: 0.08, bridge: 0.12)
            guard islands.count >= 2, let kept = islands.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) else { continue }
            for island in islands where island != kept {
                // Cut from the end of the neighboring speech to the start of the next, so the gap goes too.
                let before = islands.last { $0.upperBound <= island.lowerBound }?.upperBound ?? word.start
                let after = islands.first { $0.lowerBound >= island.upperBound }?.lowerBound ?? word.end
                let start = min(island.lowerBound, before + 0.05)
                let end = max(island.upperBound, after - 0.05)
                if end > start { cuts.append(start...end) }
            }
        }
        return cuts
    }
}
