import Foundation

/// WebVTT subtitles built from a transcript, a few words per cue.
public enum Captions {
    public static func webVTT(from transcript: Transcript, edit: Edit = Edit(), duration: Double, wordsPerCue: Int = 7) -> String {
        var lines = ["WEBVTT", ""]
        let words = transcript.words.compactMap { word -> TranscriptWord? in
            guard let start = edit.editedTime(forSourceTime: word.start, duration: duration),
                  let end = edit.editedTime(forSourceTime: min(word.end, duration), duration: duration) else { return nil }
            return TranscriptWord(text: word.text, start: start, end: max(end, start))
        }
        var index = 0
        while index < words.count {
            var cue = Array(words[index..<min(index + wordsPerCue, words.count)])
            // End a cue early at a sentence boundary so captions read naturally.
            if let stop = cue.firstIndex(where: { $0.text.last.map { ".?!".contains($0) } ?? false }), stop < cue.count - 1 {
                cue = Array(cue[...stop])
            }
            lines.append("\(timestamp(cue.first!.start)) --> \(timestamp(cue.last!.end))")
            lines.append(cue.map(\.text).joined(separator: " "))
            lines.append("")
            index += cue.count
        }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let secs = totalMilliseconds / 1000 % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
