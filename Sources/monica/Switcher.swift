import Foundation

/// Switches focus to a given agent's tmux pane and raises the configured
/// terminal app.
///
/// `,tmux-ai-agents` gets away with a bare `tmux switch-client -t <target>`
/// because it runs inside a tmux popup, where there's an implicit "current
/// client". monica runs outside tmux entirely, so it has to name a client
/// explicitly. See DESIGN.md's "Switching, precisely" section.
enum Switcher {
  /// Last time each pane was switched to via `activate` (not
  /// `sendMessage`, which doesn't count as "visiting" a pane) — backs the
  /// "Recently switched to" `SortMode`. In-memory only, not persisted
  /// across launches, which is fine since it's meant to reflect this
  /// session's own recent activity rather than a durable history.
  private static var lastActivatedAt: [String: Date] = [:]

  static func lastActivated(_ paneId: String) -> Date? {
    lastActivatedAt[paneId]
  }

  static func activate(_ session: AgentSession, targetApp: String) {
    lastActivatedAt[session.paneId] = Date()
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

  /// Sends text + Enter directly to the pane without switching focus to it
  /// — same intent as `,tmux-ai-agents`'s `alt-enter` binding, but via
  /// `set-buffer`/`paste-buffer -p` rather than `send-keys` with a literal
  /// string argument. `send-keys` simulates each character as a real
  /// keystroke, so an embedded newline (now possible via the popover's
  /// multi-line compose field, Shift+Return) would itself act as a
  /// premature Return partway through the message — confirmed with a
  /// throwaway tmux pane running bash/python3, where a literal embedded
  /// newline executes the first line immediately regardless of send-keys
  /// vs. plain paste-buffer. `-p` requests bracketed-paste wrapping
  /// (`\e[200~...\e[201~`), which is a documented no-op unless the target
  /// program has itself asked the terminal for bracketed paste — so this
  /// is a no-regression change for plain shells (same behavior confirmed
  /// above) and a real fix for TUIs that do request it, which Claude
  /// Code's and pi's Ink-based input boxes are expected to, being
  /// interactive multi-line-capable prompts themselves.
  static func sendMessage(_ session: AgentSession, text: String) {
    TmuxCLI.run(["set-buffer", "-b", messageBufferName, text])
    TmuxCLI.run(["paste-buffer", "-p", "-b", messageBufferName, "-d", "-t", session.paneId])
    TmuxCLI.run(["send-keys", "-t", session.paneId, "Enter"])
  }

  /// Named (rather than the default) tmux buffer, so this doesn't clobber
  /// whatever the user has in their own default paste buffer — deleted
  /// after use via `paste-buffer -d`.
  private static let messageBufferName = "monica-send-message"

  /// Kills the tmux pane outright, ending whatever agent process is running
  /// in it — offered from the row context menu for cleaning up stale/dead
  /// sessions without leaving the popover.
  static func killPane(_ session: AgentSession) {
    TmuxCLI.run(["kill-pane", "-t", session.paneId])
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
