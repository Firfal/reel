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
