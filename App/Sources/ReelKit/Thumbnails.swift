import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnails {
    /// A JPEG frame from `videoURL` at `time` seconds, at most `maxWidth` pixels wide.
    @concurrent
    public static func jpeg(from videoURL: URL, at time: Double = 1, maxWidth: CGFloat = 1280) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

extension Thumbnails {
    /// A short looping GIF preview: `seconds` of video from `start`, at `fps`, at most `maxWidth` pixels wide.
    @concurrent
    public static func gif(from videoURL: URL, start: Double = 0.5, seconds: Double = 3, fps: Double = 8, maxWidth: CGFloat = 480) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let begin = min(start, max(0, duration - seconds))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(min(seconds, duration) * fps))
        let times = (0..<count).map { CMTime(seconds: begin + Double($0) / fps, preferredTimescale: 600) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(destination, image, frameProperties) }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
