import Foundation

/// UserDefaults-backed custom names for agent sessions, keyed by the agent's
/// pid (`AgentSession.agentPid`) — the name follows the agent *process*, so it
/// survives moving the pane between windows/sessions and stays gone once that
/// agent exits. Pids do get reused by the OS eventually, so a leftover name
/// can land on an unrelated later agent — rename/clear it, the store
/// deliberately doesn't try to detect that.
///
/// Names are never pruned automatically: the dictionary stays tiny, and
/// pruning on scan would drop a name whenever a scan briefly missed the agent.
enum SessionNameStore {
  private static let key = "monica.customNames"

  static func name(for pid: Int32) -> String? {
    let names = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
    return names?[String(pid)]
  }

  /// A `nil` or all-whitespace name clears the entry, so renaming to an empty
  /// string is how a custom name is removed.
  static func setName(_ name: String?, for pid: Int32) {
    var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      names[String(pid)] = trimmed
    } else {
      names.removeValue(forKey: String(pid))
    }
    UserDefaults.standard.set(names, forKey: key)
  }
}
