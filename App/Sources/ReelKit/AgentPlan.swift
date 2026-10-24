import Foundation

/// Turns an agent-mode recording into a prompt an AI agent can act on: what was said, and every click in order,
/// with the app, window, address and the text clicked, each pointing to a screenshot.
public enum AgentPlan {
    public static func markdown(title: String, events: [AgentEvent], transcript: Transcript?, folder: URL, shareURL: URL? = nil) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("Enregistrement d'écran capté par Reel pour un agent. Les étapes ci-dessous sont dans l'ordre, avec ce que la personne a dit et fait. Les captures sont dans `\(folder.path)`.")
        if let shareURL { lines.append("Vidéo : \(shareURL.absoluteString)") }
        lines.append("")

        if let transcript, !transcript.words.isEmpty {
            lines.append("## Ce qui est dit")
            lines.append("")
            lines.append(transcript.text)
            lines.append("")
        }

        lines.append("## Étapes captées")
        lines.append("")
        if events.isEmpty {
            lines.append("Aucun clic pendant l'enregistrement.")
        }
        for (index, event) in events.enumerated() {
            var where_ = event.app
            if let window = event.window { where_ += " — \(window)" }
            let action = event.kind == .rightClick ? "Clic droit" : "Clic"
            let target = event.target.map { " sur « \($0) »" } ?? " en (\(Int(event.x)), \(Int(event.y)))"
            lines.append("\(index + 1). [\(clock(event.time))] \(action)\(target) dans \(where_).")
            if let url = event.url { lines.append("   Adresse : \(url)") }
            if let said = said(around: event.time, in: transcript) { lines.append("   Dit : « \(said) »") }
            if let screenshot = event.screenshot { lines.append("   Capture : `\(screenshot)`") }
        }
        lines.append("")
        lines.append("## Ce que j'attends de toi")
        lines.append("")
        lines.append("Reproduis ou analyse ce parcours d'après les étapes et ce qui est dit. Dis-moi ce que tu comprends de l'objectif, propose un plan, puis exécute-le.")
        return lines.joined(separator: "\n")
    }

    /// The words spoken from 2 seconds before to 4 seconds after a click.
    static func said(around time: Double, in transcript: Transcript?) -> String? {
        guard let transcript else { return nil }
        let words = transcript.words.filter { $0.end >= time - 2 && $0.start <= time + 4 }.map(\.text)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
