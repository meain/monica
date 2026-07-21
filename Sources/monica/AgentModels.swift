import Foundation

enum AgentStatus: String, Comparable {
  case idle
  case waiting
  case working

  /// working > waiting > idle, matching `,tmux-claude-status`'s priority rule.
  private var priority: Int {
    switch self {
    case .idle: return 0
    case .waiting: return 1
    case .working: return 2
    }
  }

  static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
    lhs.priority < rhs.priority
  }

  /// Same glyphs `,tmux-ai-agents` uses in its fzf list.
  var glyph: String {
    switch self {
    case .working: return "▶"
    case .waiting: return "●"
    case .idle: return "○"
    }
  }
}

struct AgentSession: Identifiable, Equatable {
  var paneId: String
  var windowId: String
  var session: String
  var windowName: String
  var panePath: String
  var agentPid: Int32
  var agentName: String
  var status: AgentStatus
  var project: String
  var lastUpdated: Date?
  /// From the aistatus file's `session_id` — used to locate the agent's own
  /// transcript for the message preview. `nil` if the status file was
  /// missing/stale (see `AgentScanner.lookupStatus`).
  var sessionId: String?

  var id: String { paneId }

  var displayTitle: String { "\(session)/\(project)" }
  var displaySubtitle: String { "\(windowName) · \(agentName)" }

  /// Same "Ns ago" / "Nm ago" / "Nh ago" thresholds `,tmux-ai-agents` uses
  /// for its TS_DISPLAY column. Computed live (not cached) so it stays
  /// accurate for as long as a row stays on screen between scans.
  var lastUpdatedDisplay: String {
    guard let lastUpdated else { return "-" }
    let elapsed = Int(Date().timeIntervalSince(lastUpdated))
    if elapsed < 0 { return "-" }
    if elapsed < 60 { return "\(elapsed)s ago" }
    if elapsed < 3600 { return "\(elapsed / 60)m ago" }
    return "\(elapsed / 3600)h ago"
  }

  private static let staleThreshold: TimeInterval = 3 * 3600
  private static let quietThreshold: TimeInterval = 15 * 60

  /// True once a *known* last-update timestamp is more than 3h old — not
  /// when it's `nil` (no status file yet is "unknown", not "stale").
  /// Doesn't change `status` itself, just how it's drawn (see
  /// `displayGlyph`) — the underlying pid is still confirmed live by the
  /// pid-tree scan either way.
  var isStale: Bool {
    guard let lastUpdated else { return false }
    return Date().timeIntervalSince(lastUpdated) > AgentSession.staleThreshold
  }

  /// True for the 15m-3h window between a normal update and going fully
  /// `isStale` — the status file hasn't been touched in a while but isn't
  /// old enough yet to distrust entirely. Doesn't change `status` itself,
  /// just how it's drawn (see `displayGlyph`).
  var isQuiet: Bool {
    guard let lastUpdated else { return false }
    let elapsed = Date().timeIntervalSince(lastUpdated)
    return elapsed > AgentSession.quietThreshold && elapsed <= AgentSession.staleThreshold
  }

  /// A dotted circle once stale (>3h), a filled gray circle once quiet
  /// (15m-3h) regardless of what `status` says, otherwise the normal
  /// status glyph.
  var displayGlyph: String {
    if isStale { return "◌" }
    if isQuiet { return "●" }
    return status.glyph
  }

  /// Used by `AgentScanner.scan()`'s `.statusPriority` `SortMode` — higher
  /// sorts first. Stale/quiet always sink below every real status
  /// (regardless of what `status` itself says, same as `displayGlyph`),
  /// since they're more likely a dead/uncertain session than one actually
  /// wanting attention; within "real" statuses this reuses `AgentStatus`'s
  /// own `working > waiting > idle` priority.
  var sortPriorityRank: Int {
    if isStale { return -2 }
    if isQuiet { return -1 }
    switch status {
    case .idle: return 0
    case .waiting: return 1
    case .working: return 2
    }
  }
}
