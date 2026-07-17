import Foundation

/// Switches focus to a given agent's tmux pane and raises the configured
/// terminal app.
///
/// `,tmux-ai-agents` gets away with a bare `tmux switch-client -t <target>`
/// because it runs inside a tmux popup, where there's an implicit "current
/// client". monica runs outside tmux entirely, so it has to name a client
/// explicitly. See DESIGN.md's "Switching, precisely" section.
enum Switcher {
    static func activate(_ session: AgentSession, targetApp: String) {
        TmuxCLI.run(["select-pane", "-t", session.paneId])

        guard let target = resolveSessionWindow(windowId: session.windowId) else {
            // Still worth raising the terminal even if we couldn't resolve the
            // exact session:window target.
            runFireAndForget("/usr/bin/open", ["-a", targetApp])
            return
        }

        if let client = firstAttachedClient() {
            TmuxCLI.run(["switch-client", "-c", client, "-t", target])
        }

        runFireAndForget("/usr/bin/open", ["-a", targetApp])
    }

    /// `#{session_name}:#{window_id}` for the given window, resolved across all
    /// sessions (a window's session can differ from a pane's session_group).
    private static func resolveSessionWindow(windowId: String) -> String? {
        let output = TmuxCLI.run(["list-windows", "-a", "-F", "#{session_name}:#{window_id}"])
        for line in output.split(separator: "\n") {
            if line.hasSuffix(":\(windowId)") {
                return String(line)
            }
        }
        return nil
    }

    /// v1 assumes a single attached tmux client (single Ghostty window). See
    /// DESIGN.md's "known gap" note for the multi-window upgrade path.
    private static func firstAttachedClient() -> String? {
        let output = TmuxCLI.run(["list-clients", "-F", "#{client_name}"])
        return output.split(separator: "\n").first.map(String.init)
    }
}
