// reel-mcp: a stdio MCP server that lets AI agents read the Reel library on this Mac.
// Tools: list_videos, get_video (transcript, summary, chapters, link), get_agent_plan.
// Register with Claude Code:
//   claude mcp add reel -- /Applications/Reel.app/Contents/MacOS/reel-mcp
import Foundation
import ReelKit

let library = Library()

func folder(_ id: String) -> URL? {
    UUID(uuidString: id).map { library.folder(for: $0) }
}

func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
}

struct Details: Decodable {
    var summary: String?
    var tasks: [String]?
    var chapters: [ShareMetadata.Chapter]?
}

let tools: [[String: Any]] = [
    [
        "name": "list_videos",
        "description": "List the screen recordings in the user's Reel library, newest first: id, title, date, duration, share link, and whether an agent plan exists.",
        "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "Optional words to match in titles."]]],
    ],
    [
        "name": "get_video",
        "description": "Get one recording: title, link, summary, chapters, tasks and the full transcript with timestamps.",
        "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
    ],
    [
        "name": "get_agent_plan",
        "description": "Get the plan captured in agent mode for a recording: every click with app, window, address, clicked text, what was said, and screenshot paths.",
        "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
    ],
]

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

func call(_ name: String, _ arguments: [String: Any]) -> (String, Bool) {
    switch name {
    case "list_videos":
        let query = (arguments["query"] as? String)?.lowercased() ?? ""
        let rows = library.items()
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
            .map { item -> String in
                let hasPlan = FileManager.default.fileExists(atPath: library.folder(for: item.id).appendingPathComponent("agent/plan.md").path)
                return "- \(item.title) | id: \(item.id.uuidString) | \(item.createdAt.formatted(.iso8601)) | \(clock(item.duration))"
                    + (item.shareURL.map { " | \($0.absoluteString)" } ?? "") + (hasPlan ? " | plan agent" : "")
            }
        return (rows.isEmpty ? "Aucune vidéo." : rows.joined(separator: "\n"), false)

    case "get_video":
        guard let id = arguments["id"] as? String, let dir = folder(id),
              let item = readJSON(VideoItem.self, dir.appendingPathComponent("item.json")) else { return ("Vidéo introuvable.", true) }
        var lines = ["# \(item.title)", "Durée : \(clock(item.duration))"]
        if let url = item.shareURL { lines.append("Lien : \(url.absoluteString)") }
        lines.append("Fichier : \(dir.appendingPathComponent("video.mp4").path)")
        if let details = readJSON(Details.self, dir.appendingPathComponent("insights.json")) {
            if let summary = details.summary, !summary.isEmpty { lines += ["", "## Résumé", summary] }
            if let chapters = details.chapters, !chapters.isEmpty { lines += ["", "## Chapitres"] + chapters.map { "- \(clock($0.time)) \($0.title)" } }
            if let tasks = details.tasks, !tasks.isEmpty { lines += ["", "## Tâches"] + tasks.map { "- \($0)" } }
        }
        if let transcript = readJSON(Transcript.self, dir.appendingPathComponent("transcript.json")), !transcript.words.isEmpty {
            lines += ["", "## Transcription"]
            var sentence: [String] = []
            var start = 0.0
            for word in transcript.words {
                if sentence.isEmpty { start = word.start }
                sentence.append(word.text)
                if let last = word.text.last, ".?!".contains(last) {
                    lines.append("[\(clock(start))] " + sentence.joined(separator: " "))
                    sentence = []
                }
            }
            if !sentence.isEmpty { lines.append("[\(clock(start))] " + sentence.joined(separator: " ")) }
        }
        return (lines.joined(separator: "\n"), false)

    case "get_agent_plan":
        guard let id = arguments["id"] as? String, let dir = folder(id),
              let plan = try? String(contentsOf: dir.appendingPathComponent("agent/plan.md"), encoding: .utf8)
        else { return ("Pas de plan agent pour cette vidéo : elle n'a pas été enregistrée en mode agent.", true) }
        return (plan, false)

    default:
        return ("Outil inconnu : \(name)", true)
    }
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }

    switch method {
    case "initialize":
        reply([
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "reel", "version": "0.1.0"],
        ])
    case "tools/list":
        reply(["tools": tools])
    case "tools/call":
        let (text, isError) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        reply(["content": [["type": "text", "text": text]], "isError": isError])
    case "ping":
        reply([:])
    default:
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
    }
}
