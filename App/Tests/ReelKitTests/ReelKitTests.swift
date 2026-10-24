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

@Suite struct EditTests {
    @Test func `overlapping cuts merge and the rest is kept`() {
        let edit = Edit(cuts: [2...4, 3...5, 8...12])
        #expect(edit.keptRanges(duration: 10) == [0...2, 5...8])
        #expect(edit.editedDuration(duration: 10) == 5)
    }

    @Test func `source times map onto the edited timeline`() {
        let edit = Edit(cuts: [2...4])
        #expect(edit.editedTime(forSourceTime: 5, duration: 10) == 3)
        #expect(edit.editedTime(forSourceTime: 3, duration: 10) == nil)
    }

    @Test func `trim cuts the head and the tail`() {
        var edit = Edit()
        edit.trim(start: 1, end: 9, duration: 10)
        #expect(edit.keptRanges(duration: 10) == [1...9])
    }
}

@Suite struct CleanupTests {
    let transcript = Transcript(locale: "fr_FR", words: [
        TranscriptWord(text: "Bonjour,", start: 0.5, end: 1.0),
        TranscriptWord(text: "euh", start: 1.1, end: 1.4),
        TranscriptWord(text: "voici", start: 4.0, end: 4.5),
        TranscriptWord(text: "Hum.", start: 4.6, end: 4.9),
    ])

    @Test func `hesitations are found regardless of case and punctuation`() {
        #expect(Cleanup.fillerWords(in: transcript).map(\.text) == ["euh", "Hum."])
    }

    @Test func `long gaps become cuts with air left around the words`() {
        let silences = Cleanup.silences(in: transcript, duration: 7)
        #expect(silences.count == 2)
        #expect(silences[0].lowerBound == 1.65 && silences[0].upperBound == 3.75)
        #expect(silences[1] == 5.15...7)
    }
}
