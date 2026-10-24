import Foundation

/// Which AI writes titles, summaries, chapters and documents. Chosen in Settings.
public enum AIEngine: String, CaseIterable, Sendable {
    /// Apple's on-device model: free and private, nothing leaves the Mac.
    case onDevice
    /// Claude through the user's own API key: better on long or technical videos.
    case claude

    static let defaultsKey = "ai.engine"

    public static var current: AIEngine {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AIEngine.init(rawValue:)) ?? .onDevice }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

public enum ClaudeKey {
    static let service = "app.reel.mac.claude"

    public static func load() -> String? { Keychain.read(service: service, account: "api-key") }
    public static func save(_ key: String) throws { try Keychain.write(key, service: service, account: "api-key") }
}

public enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Ajoute ta clé Claude dans Réglages › IA, ou choisis l'IA sur ton Mac."
        case .http(let status, let message): "Claude a répondu \(status) : \(message)"
        case .refused: "Claude a refusé cette demande."
        case .unreadable: "La réponse de Claude est illisible."
        }
    }
}

/// Raw HTTP client for the Messages API (Swift has no official Anthropic SDK).
struct ClaudeClient {
    let apiKey: String
    var model = "claude-opus-5-5"
    var session = URLSession.shared

    /// Sends one request and returns the text of the reply. With `schema`, the reply is JSON matching it.
    func respond(system: String, prompt: String, schema: [String: Any]? = nil, maxTokens: Int = 16_000) async throws -> String {
        var outputConfig: [String: Any] = ["effort": "low"]
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": outputConfig,
            // If a safety classifier declines, the API retries on a suitable model inside the same call.
            "fallbacks": "default",
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw ClaudeError.http(status, message)
        }
        guard let json else { throw ClaudeError.unreadable }
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClaudeError.unreadable }
        return text
    }
}

extension VideoAI {
    static var insightsSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "summary", "chapters", "tasks", "callToAction"],
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "chapters": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["line", "title"],
                    "properties": ["line": ["type": "integer"], "title": ["type": "string"]],
                ],
            ],
            "tasks": ["type": "array", "items": ["type": "string"]],
            "callToAction": ["type": ["string", "null"]],
        ],
    ] }

    /// Same output as the on-device path, written by Claude.
    static func claudeInsights(numbered: String, duration: Double, key: String) async throws -> (title: String, summary: String, chapters: [(line: Int, title: String)], tasks: [String], cta: String?) {
        let text = try await ClaudeClient(apiKey: key).respond(
            system: """
            You help people share screen recordings. From a numbered transcript, write in the transcript's language: \
            a specific title of 3 to 8 words; a summary of two or three plain sentences; 2 to 8 chapters, each naming \
            the line where it begins (the first begins at line 1) with a 2 to 5 word title; concrete next actions the \
            speaker mentioned, as short imperative sentences (empty if none); and a 2 to 4 word call to action only if \
            the speaker asks the viewer to do something, else null. Use only what the transcript says.
            """,
            prompt: "Video length: \(Int(duration)) seconds.\n\nTranscript:\n\(numbered)",
            schema: insightsSchema
        )
        guard let data = text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.unreadable
        }
        let chapters = (json["chapters"] as? [[String: Any]] ?? []).compactMap { chapter -> (Int, String)? in
            guard let line = chapter["line"] as? Int, let title = chapter["title"] as? String else { return nil }
            return (line, title)
        }
        return (
            json["title"] as? String ?? "",
            json["summary"] as? String ?? "",
            chapters,
            json["tasks"] as? [String] ?? [],
            json["callToAction"] as? String
        )
    }
}
