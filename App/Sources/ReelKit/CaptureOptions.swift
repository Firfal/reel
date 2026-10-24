import CoreGraphics
import Foundation

/// What to record.
public enum CaptureSource: Sendable, Hashable {
    /// A whole display.
    case display(CGDirectDisplayID)
    /// A single window, followed wherever it moves.
    case window(CGWindowID)
    /// Part of a display. The rect is in display points, origin at the top-left.
    case region(CGDirectDisplayID, CGRect)
}

/// Output resolution, expressed as the target height. Width follows the source's aspect ratio.
public enum CaptureQuality: String, Codable, Sendable, CaseIterable {
    case p720, p1080, p1440, p2160

    public var height: Int {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        }
    }
}

public struct CaptureOptions: Sendable {
    public var source: CaptureSource
    public var quality: CaptureQuality
    /// Overrides `quality` with exact output dimensions (custom recording size).
    public var customSize: CGSize?
    public var framesPerSecond: Int
    public var capturesSystemAudio: Bool
    /// `nil` records no microphone. Use `MicrophoneDevice.systemDefaultID` for the default input.
    public var microphoneID: String?
    public var showsCursor: Bool
    public var showsMouseClicks: Bool
    /// Windows never recorded, such as the recording control bar.
    public var excludedWindowIDs: [CGWindowID]

    public init(
        source: CaptureSource,
        quality: CaptureQuality = .p1080,
        customSize: CGSize? = nil,
        framesPerSecond: Int = 30,
        capturesSystemAudio: Bool = true,
        microphoneID: String? = MicrophoneDevice.systemDefaultID,
        showsCursor: Bool = true,
        showsMouseClicks: Bool = false,
        excludedWindowIDs: [CGWindowID] = []
    ) {
        self.source = source
        self.quality = quality
        self.customSize = customSize
        self.framesPerSecond = framesPerSecond
        self.capturesSystemAudio = capturesSystemAudio
        self.microphoneID = microphoneID
        self.showsCursor = showsCursor
        self.showsMouseClicks = showsMouseClicks
        self.excludedWindowIDs = excludedWindowIDs
    }

    /// Output pixel size for a source of `sourceSize` points. Even numbers, as H.264 requires.
    public func outputSize(forSourceSize sourceSize: CGSize) -> CGSize {
        if let customSize {
            return CGSize(width: Self.even(customSize.width), height: Self.even(customSize.height))
        }
        guard sourceSize.height > 0 else { return .zero }
        let height = CGFloat(quality.height)
        let width = height * sourceSize.width / sourceSize.height
        return CGSize(width: Self.even(width), height: Self.even(height))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

public enum MicrophoneDevice {
    /// Placeholder meaning "the system's default input device".
    public static let systemDefaultID = "default"
}
