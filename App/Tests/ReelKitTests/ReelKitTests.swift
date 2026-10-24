import CoreGraphics
import Foundation
import Testing
@testable import ReelKit

@Suite struct CaptureOptionsTests {
    @Test func `output keeps the source aspect ratio at the target height`() {
        let options = CaptureOptions(source: .display(1), quality: .p1080)
        #expect(options.outputSize(forSourceSize: CGSize(width: 1512, height: 982)) == CGSize(width: 1662, height: 1080))
    }

    @Test func `custom size wins and is rounded to even pixels`() {
        let options = CaptureOptions(source: .display(1), customSize: CGSize(width: 1281, height: 719))
        #expect(options.outputSize(forSourceSize: CGSize(width: 100, height: 100)) == CGSize(width: 1282, height: 720))
    }
}

@Suite struct RewindTests {
    let segments = [Segment(url: URL(filePath: "/a")), Segment(url: URL(filePath: "/b"))]

    @Test func `rewind trims the last segment first`() {
        let result = segments.rewound(by: 2, durations: [5, 4])
        #expect(result.map(\.trimTail) == [0, 2])
    }

    @Test func `rewind longer than the last segment spills into the previous one`() {
        let result = segments.rewound(by: 6, durations: [5, 4])
        #expect(result.map(\.trimTail) == [2, 4])
    }

    @Test func `rewind never goes below the start`() {
        let result = segments.rewound(by: 60, durations: [5, 4])
        #expect(result.map(\.trimTail) == [5, 4])
    }
}

@Suite struct LibraryTests {
    @Test func `saved items come back newest first`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let old = VideoItem(title: "Ancienne", createdAt: Date(timeIntervalSince1970: 0), duration: 3)
        let new = VideoItem(title: "Récente", createdAt: Date(timeIntervalSince1970: 100), duration: 5)
        try library.save(old)
        try library.save(new)
        #expect(library.items().map(\.title) == ["Récente", "Ancienne"])
    }

    @Test func `default title is in French`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 41))!
        #expect(VideoItem.defaultTitle(for: date) == "Vidéo du 24 oct. à 23:41")
    }
}
