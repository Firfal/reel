import AVFoundation
import Foundation

/// A non-destructive edit: the parts of the source video to drop, in seconds.
/// The source file is never modified; `Composer.render` applies the edit on export.
public struct Edit: Codable, Sendable, Hashable {
    public var cuts: [ClosedRange<Double>]

    public init(cuts: [ClosedRange<Double>] = []) {
        self.cuts = cuts
    }

    /// Cuts merged and clamped to `0...duration`, sorted.
    public func normalizedCuts(duration: Double) -> [ClosedRange<Double>] {
        let clamped = cuts
            .map { max(0, $0.lowerBound)...min(duration, $0.upperBound) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for cut in clamped {
            if let last = merged.last, cut.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cut.upperBound)
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    /// The ranges that stay, in order.
    public func keptRanges(duration: Double) -> [ClosedRange<Double>] {
        var kept: [ClosedRange<Double>] = []
        var cursor = 0.0
        for cut in normalizedCuts(duration: duration) {
            if cut.lowerBound > cursor { kept.append(cursor...cut.lowerBound) }
            cursor = cut.upperBound
        }
        if cursor < duration { kept.append(cursor...duration) }
        return kept
    }

    /// Length of the edited video.
    public func editedDuration(duration: Double) -> Double {
        keptRanges(duration: duration).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    /// Maps a time in the source to the edited timeline, or `nil` if that moment was cut.
    public func editedTime(forSourceTime time: Double, duration: Double) -> Double? {
        var offset = 0.0
        for range in keptRanges(duration: duration) {
            if range.contains(time) { return offset + time - range.lowerBound }
            offset += range.upperBound - range.lowerBound
        }
        return nil
    }

    // MARK: Building cuts

    public mutating func trim(start: Double, end: Double, duration: Double) {
        if start > 0 { cuts.append(0...start) }
        if end < duration { cuts.append(end...duration) }
    }

    /// Cuts the given words (struck out in the transcript).
    public mutating func cut(words: [TranscriptWord]) {
        cuts += words.map { $0.start...$0.end }
    }
}

/// Finds hesitations and silences in a transcript.
public enum Cleanup {
    /// Hesitation words, lowercased, without punctuation. French first, then English.
    static let fillers: Set<String> = [
        "euh", "heu", "hum", "hmm", "bah", "ben", "beh", "eh",
        "uh", "um", "uhm", "erm", "ah",
    ]

    public static func fillerWords(in transcript: Transcript) -> [TranscriptWord] {
        transcript.words.filter { fillers.contains(normalize($0.text)) }
    }

    /// Gaps between words longer than `minimum` seconds, keeping `padding` of air on each side.
    public static func silences(
        in transcript: Transcript,
        duration: Double,
        minimum: Double = 1.2,
        padding: Double = 0.25
    ) -> [ClosedRange<Double>] {
        var boundaries = [0.0]
        for word in transcript.words { boundaries += [word.start, word.end] }
        boundaries.append(duration)
        var silences: [ClosedRange<Double>] = []
        for index in stride(from: 0, to: boundaries.count - 1, by: 2) {
            let gapStart = boundaries[index]
            let gapEnd = boundaries[index + 1]
            guard gapEnd - gapStart >= minimum else { continue }
            let start = index == 0 ? 0 : gapStart + padding
            let end = index + 1 == boundaries.count - 1 ? duration : gapEnd - padding
            if end > start { silences.append(start...end) }
        }
        return silences
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

extension Composer {
    /// Exports `source` with `edit` applied. Returns the edited duration in seconds.
    @concurrent
    public static func render(_ source: URL, edit: Edit, to destination: URL) async throws -> Double {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let kept = edit.keptRanges(duration: duration)
        guard !kept.isEmpty else { throw ComposerError.noSegments }

        let composition = AVMutableComposition()
        var targets: [AVMutableCompositionTrack?] = []
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            targets.append(composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
        }
        var cursor = CMTime.zero
        for range in kept {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
            for (track, target) in zip(tracks, targets) {
                try target?.insertTimeRange(timeRange, of: track, at: cursor)
            }
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ComposerError.exportUnavailable
        }
        try await export.export(to: destination, as: .mp4)
        return composition.duration.seconds
    }
}
