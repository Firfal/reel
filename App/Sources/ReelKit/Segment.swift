import Foundation

/// One continuous piece of a recording. Pausing or rewinding closes the current segment and opens a new one;
/// the segments are stitched together when the recording stops.
public struct Segment: Codable, Sendable, Hashable {
    public var url: URL
    /// Seconds to drop from the end of this segment (Live Rewind).
    public var trimTail: Double

    public init(url: URL, trimTail: Double = 0) {
        self.url = url
        self.trimTail = trimTail
    }
}

extension [Segment] {
    /// Applies a rewind of `seconds` to already-closed segments, given each segment's duration.
    /// The rewind eats into the last segment first, then into earlier ones, and never goes below zero.
    public func rewound(by seconds: Double, durations: [Double]) -> [Segment] {
        precondition(durations.count == count, "one duration per segment")
        var remaining = seconds
        var result = self
        for index in result.indices.reversed() where remaining > 0 {
            let available = Swift.max(0, durations[index] - result[index].trimTail)
            let cut = Swift.min(available, remaining)
            result[index].trimTail += cut
            remaining -= cut
        }
        return result
    }
}
