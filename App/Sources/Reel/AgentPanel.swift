import AppKit
import SwiftUI

/// The editor's Agent tab: the plan built from an agent-mode recording, ready to hand to Claude.
struct AgentPanel: View {
    let folder: URL
    @State private var plan = ""
    @State private var copied = false

    private var planURL: URL { folder.appendingPathComponent("plan.md") }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            InspectorHint("Les clics et ta voix, fusionnés en un plan qu'un agent peut suivre.")
            ScrollView {
                Text(plan)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.small)
            }
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            HStack {
                Button(copied ? "Copié" : "Copier le prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Ouvrir dans Claude Code", action: openInClaudeCode)
                Spacer()
                Button("Captures") { NSWorkspace.shared.open(folder) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.bottom, Theme.Spacing.section)
        .onAppear { plan = (try? String(contentsOf: planURL, encoding: .utf8)) ?? "" }
    }

    /// Opens Terminal in the captures folder and starts Claude Code with the plan as its first prompt.
    /// A .command file opens in Terminal without asking to control it.
    private func openInClaudeCode() {
        let script = folder.appendingPathComponent("Ouvrir dans Claude Code.command")
        let body = """
        #!/bin/zsh -l
        cd \(shellQuote(folder.path))
        claude "$(cat plan.md)"
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
