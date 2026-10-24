import AVFoundation
import Foundation

public enum ComposerError: LocalizedError {
    case noSegments
    case exportUnavailable

    public var errorDescription: String? {
        switch self {
        case .noSegments: "La vidéo est vide."
        case .exportUnavailable: "Impossible d'exporter la vidéo sur ce Mac."
        }
    }
}

/// Stitches recording segments (or any clips) into one movie, honoring each segment's trimmed tail.
public enum Composer {
    /// Writes the stitched movie to `destination` (MP4) and returns its duration in seconds.
    @concurrent
    public static func stitch(_ segments: [Segment], to destination: URL) async throws -> Double {
        guard !segments.isEmpty else { throw ComposerError.noSegments }
        try? FileManager.default.removeItem(at: destination)

        if segments.count == 1, segments[0].trimTail == 0 {
            try FileManager.default.copyItem(at: segments[0].url, to: destination)
            return try await AVURLAsset(url: destination).load(.duration).seconds
        }

        let composition = try await makeComposition(segments)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ComposerError.exportUnavailable
        }
        try await export.export(to: destination, as: .mp4)
        return composition.duration.seconds
    }

    static func makeComposition(_ segments: [Segment]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        var tracksByKey: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            let duration = try await asset.load(.duration)
            let kept = CMTimeSubtract(duration, CMTime(seconds: segment.trimTail, preferredTimescale: 600))
            guard kept > .zero else { continue }
            let range = CMTimeRange(start: .zero, duration: kept)

            let tracks = try await asset.load(.tracks)
            var indexByType: [AVMediaType: Int] = [:]
            for track in tracks {
                let index = indexByType[track.mediaType, default: 0]
                indexByType[track.mediaType] = index + 1
                let key = "\(track.mediaType.rawValue)-\(index)"
                let target = tracksByKey[key] ?? composition.addMutableTrack(
                    withMediaType: track.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                guard let target else { continue }
                tracksByKey[key] = target
                try target.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = CMTimeAdd(cursor, kept)
        }
        return composition
    }
}
