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

    @Test func `short pauses inside a sentence are hesitations, not those after punctuation`() {
        let words = Transcript(locale: "fr_FR", words: [
            TranscriptWord(text: "voici", start: 0, end: 0.5),
            TranscriptWord(text: "le", start: 1.2, end: 1.3),        // 0.7 s pause mid-sentence: hesitation
            TranscriptWord(text: "point.", start: 1.4, end: 1.8),
            TranscriptWord(text: "Le", start: 2.6, end: 2.7),        // 0.8 s after a full stop: kept
        ])
        let pauses = Cleanup.hesitationPauses(in: words)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].lowerBound - 0.58) < 0.001 && abs(pauses[0].upperBound - 1.12) < 0.001)
    }

    @Test func `long gaps become cuts with air left around the words`() {
        let silences = Cleanup.silences(in: transcript, duration: 7)
        #expect(silences.count == 2)
        #expect(silences[0].lowerBound == 1.65 && silences[0].upperBound == 3.75)
        #expect(silences[1] == 5.15...7)
    }
}

@Suite struct AudioAnalysisTests {
    /// 20 ms steps: speech at -20 dB, silence at -60 dB.
    func levels(_ pattern: [(seconds: Double, loud: Bool)]) -> AudioLevels {
        AudioLevels(step: 0.02, decibels: pattern.flatMap { Array(repeating: $0.loud ? Float(-20) : -60, count: Int(($0.seconds / 0.02).rounded())) })
    }

    @Test func `quiet stretches become silences with air kept around speech`() {
        let audio = levels([(1, true), (2, false), (1, true)])
        let silences = audio.silences(duration: 4)
        #expect(silences.count == 1)
        #expect(abs(silences[0].lowerBound - 1.2) < 0.03 && abs(silences[0].upperBound - 2.8) < 0.03)
    }

    @Test func `an extra burst inside an over-long word is a hesitation`() {
        // "On" lasts 1.4 s: 0.3 s of « euh », a pause, then the word itself.
        let audio = levels([(0.3, true), (0.5, false), (0.3, true), (0.3, false), (0.5, true)])
        let transcript = Transcript(locale: "fr_FR", words: [TranscriptWord(text: "On", start: 1.1, end: 1.9)])
        let wide = Transcript(locale: "fr_FR", words: [TranscriptWord(text: "On", start: 0.8, end: 1.9)])
        // Timed tightly on the word itself: one burst only, nothing to cut.
        #expect(Cleanup.hesitations(in: transcript, levels: audio).isEmpty)
        let cuts = Cleanup.hesitations(in: wide, levels: audio)
        #expect(cuts.count == 1)
        #expect(cuts[0].lowerBound <= 0.8 && cuts[0].upperBound >= 1.3 && cuts[0].upperBound < 1.4)
    }
}
