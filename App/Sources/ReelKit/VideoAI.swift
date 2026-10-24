import Foundation
import FoundationModels

/// What the AI proposes for a video. The user reviews it before it goes on the share page.
@Generable
public struct VideoInsights: Codable, Sendable, Hashable {
    @Guide(description: "A short, specific title in the video's language, 3 to 8 words, no quotes, no trailing period.")
    public var title: String

    @Guide(description: "Two or three plain sentences saying what the video shows and why it matters to the viewer.")
    public var summary: String

    @Guide(description: "Chapters in order, each where the topic changes. The first begins at line 1. Each title is 2 to 5 words.", .count(2...8))
    public var chapters: [Chapter]

    @Guide(description: "Concrete next actions someone mentioned or asked for, as short imperative sentences. Empty if none.", .maximumCount(6))
    public var tasks: [String]

    @Guide(description: "A call to action for the viewer if the speaker asks for one (book a call, reply, review a document), else nil. 2 to 4 words.")
    public var callToAction: String?

    @Generable
    public struct Chapter: Codable, Sendable, Hashable {
        @Guide(description: "Number of the transcript line where this chapter begins, as shown in brackets at the start of the line.")
        public var line: Int
        public var title: String
        /// Start time in seconds, filled in by the app from `line`.
        @Guide(description: "Always 0; the app computes it.")
        public var start: Int
    }
}

/// The kinds of written document a video can become.
public enum DocumentKind: String, CaseIterable, Sendable, Identifiable {
    case procedure, ticket, message
    public var id: Self { self }

    public var label: String {
        switch self {
        case .procedure: "Procédure"
        case .ticket: "Ticket"
        case .message: "Message"
        }
    }

    var instructions: String {
        switch self {
        case .procedure:
            "Write a standard operating procedure in Markdown: a title (#), one sentence of purpose, then numbered steps. Each step is one action, starts with a verb, and ends with its timestamp in the video in parentheses, like (1:45). Add a short « Points d'attention » list only if the speaker warns about something."
        case .ticket:
            "Write a bug or task ticket in Markdown with these sections: # title, ## Contexte, ## Étapes pour reproduire (numbered, with timestamps), ## Résultat attendu, ## Résultat obtenu. If the video is not about a problem, write a task ticket: # title, ## Contexte, ## À faire (checklist)."
        case .message:
            "Write a short message to send with the video link, in the speaker's voice and language: a greeting, two to four sentences on what the video covers and what is expected from the reader, then a sign-off. No subject line, no Markdown headings."
        }
    }
}

public enum VideoAIError: LocalizedError {
    case unavailable(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .emptyTranscript: "La vidéo n'a pas de paroles à analyser."
        }
    }
}

/// On-device AI with Apple's Foundation Models. Nothing leaves the Mac.
public enum VideoAI {
    /// Why the on-device model can't run, or nil when it can.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Active Apple Intelligence dans Réglages Système pour utiliser l'IA sur ton Mac."
        case .unavailable(.deviceNotEligible): "Ce Mac ne prend pas en charge Apple Intelligence. Ajoute une clé Claude dans les réglages."
        case .unavailable(.modelNotReady): "Le modèle d'Apple Intelligence se télécharge encore. Réessaie dans quelques minutes."
        case .unavailable: "L'IA sur l'appareil n'est pas disponible."
        }
    }

    @concurrent
    public static func insights(for transcript: Transcript, duration: Double) async throws -> VideoInsights {
        guard !transcript.words.isEmpty else { throw VideoAIError.emptyTranscript }
        let sentences = Self.sentences(transcript, maxWords: AIEngine.current == .claude ? 60_000 : 1800)
        let numbered = sentences.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")

        var insights: VideoInsights
        if AIEngine.current == .claude {
            guard let key = ClaudeKey.load() else { throw ClaudeError.missingKey }
            let reply = try await claudeInsights(numbered: numbered, duration: duration, key: key)
            insights = VideoInsights(
                title: reply.title,
                summary: reply.summary,
                chapters: reply.chapters.map { .init(line: $0.line, title: $0.title, start: 0) },
                tasks: reply.tasks,
                callToAction: reply.cta
            )
        } else {
            if let reason = unavailableReason { throw VideoAIError.unavailable(reason) }
            let session = LanguageModelSession(instructions: """
                You help people share screen recordings. You read a transcript and describe the video \
                accurately, in the transcript's language. Never invent facts that are not in the transcript. \
                Each transcript line starts with its number in brackets.
                """)
            insights = try await session.respond(
                to: "Video length: \(Int(duration)) seconds.\n\nTranscript:\n\(numbered)",
                generating: VideoInsights.self
            ).content
        }

        // Turn line numbers into times; keep one chapter per line, in order, the first at 0.
        var seen = Set<Int>()
        insights.chapters = insights.chapters
            .filter { (1...max(1, sentences.count)).contains($0.line) && seen.insert($0.line).inserted && $0.line <= sentences.count }
            .sorted { $0.line < $1.line }
            .map { chapter in
                var chapter = chapter
                chapter.start = Int(sentences[chapter.line - 1].start)
                return chapter
            }
        if !insights.chapters.isEmpty { insights.chapters[0].start = 0 }
        if insights.chapters.count < 2 { insights.chapters = [] }
        return insights
    }

    @concurrent
    public static func document(_ kind: DocumentKind, for transcript: Transcript, title: String) async throws -> String {
        guard !transcript.words.isEmpty else { throw VideoAIError.emptyTranscript }
        if AIEngine.current == .claude {
            guard let key = ClaudeKey.load() else { throw ClaudeError.missingKey }
            return try await ClaudeClient(apiKey: key).respond(
                system: "You turn a narrated screen recording into a written document, in the transcript's language. Use only what the speaker says. \(kind.instructions)",
                prompt: "Video title: \(title)\n\nTranscript:\n\(timestampedLines(transcript, maxWords: 60_000))"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let reason = unavailableReason { throw VideoAIError.unavailable(reason) }
        let session = LanguageModelSession(instructions: """
            You turn a narrated screen recording into a written document, in the transcript's language. \
            Use only what the speaker says. \(kind.instructions)
            """)
        let response = try await session.respond(to: "Video title: \(title)\n\nTranscript:\n\(timestampedLines(transcript, maxWords: 1800))")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns rough dictated thoughts into short talking points for the teleprompter, one per line.
    @concurrent
    public static func talkingPoints(from spoken: String) async throws -> String {
        let instructions = "Turn these rough spoken notes into 3 to 7 short talking points, in the same language, one per line, each starting with « – ». Keep the speaker's ideas and order; add nothing."
        if AIEngine.current == .claude, let key = ClaudeKey.load() {
            return try await ClaudeClient(apiKey: key).respond(system: instructions, prompt: spoken, maxTokens: 2_000)
        }
        if let reason = unavailableReason { throw VideoAIError.unavailable(reason) }
        return try await LanguageModelSession(instructions: instructions).respond(to: spoken).content
    }

    /// The transcript cut into sentences (at most 30 words each), up to `maxWords` to fit the model's context.
    static func sentences(_ transcript: Transcript, maxWords: Int) -> [(start: Double, text: String)] {
        var sentences: [(start: Double, text: String)] = []
        var current: [String] = []
        var start: Double?
        for word in transcript.words.prefix(maxWords) {
            if start == nil { start = word.start }
            current.append(word.text)
            if let last = word.text.last, ".?!".contains(last) || current.count >= 30 {
                sentences.append((start!, current.joined(separator: " ")))
                current = []
                start = nil
            }
        }
        if let start, !current.isEmpty { sentences.append((start, current.joined(separator: " "))) }
        return sentences
    }

    /// The transcript as « [m:ss] sentence » lines, for documents that cite timestamps.
    static func timestampedLines(_ transcript: Transcript, maxWords: Int) -> String {
        sentences(transcript, maxWords: maxWords).map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
