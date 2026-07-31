import Foundation

/// Only two live states: `working` (Claude Code's `busy`) and `idle`
/// (everything else — the agent finished its turn and is awaiting you).
/// There is deliberately no `waiting` — the sessions-file status monica now
/// reads (see `AgentScanner.lookupStatus`) only distinguishes busy/idle, so a
/// separate "blocked on you" state can't be told apart reliably; it collapses
/// into `idle`. Staleness (see `AgentSession.isQuiet`/`isStale`) is a separate
/// time-based overlay, not a status value.
enum AgentStatus: String, Comparable {
  case idle
  case working

  /// working > idle.
  private var priority: Int {
    switch self {
    case .idle: return 0
    case .working: return 1
    }
  }

  static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
    lhs.priority < rhs.priority
  }

  /// Same glyphs `,tmux-ai-agents` uses in its fzf list.
  var glyph: String {
    switch self {
    case .working: return "▶"
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
  /// The agent's session id — used to locate the agent's own transcript for
  /// the message preview. For claude it comes from `~/.claude/sessions/<pid>.json`,
  /// for pi from the aistatus file's `session_id`. `nil` if neither source
  /// had it (see `AgentScanner.lookupStatus`).
  var sessionId: String?
  /// User-assigned name for this session (⌘R / the row's "Rename…" context
  /// menu action), read from `SessionNameStore` on each scan. Purely a
  /// display/filter alias — sorting and identity still use `project`/`paneId`.
  var customName: String?
  /// The agent's own session name, when it has a meaningful one — currently
  /// only Claude Code, read from `~/.claude/sessions/<pid>.json` on each scan
  /// (see `AgentScanner.lookupClaudeSessionName`). Always nil for pi.
  var agentSessionName: String?

  var id: String { paneId }

  /// What the row's bold title shows, in priority order: the name set in
  /// monica, then the agent's own session name, then the project.
  var displayName: String { customName ?? agentSessionName ?? project }

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

  /// True once a last-update timestamp is more than 3h old, *or* there's no
  /// status file for this pid at all (`lastUpdated == nil`) — no file
  /// means we have no real signal for this session, which is just as
  /// untrustworthy as a stale one. Doesn't change `status` itself, just how
  /// it's drawn (see `displayGlyph`) — the underlying pid is still confirmed
  /// live by the pid-tree scan either way.
  var isStale: Bool {
    guard let lastUpdated else { return true }
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
  /// own `working > idle` priority. Sorted descending, this yields
  /// working → idle → quiet → stale.
  var sortPriorityRank: Int {
    if isStale { return -2 }
    if isQuiet { return -1 }
    switch status {
    case .idle: return 0
    case .working: return 1
    }
  }

  /// Used by `AgentScanner.scan()`'s `.needsAttention` `SortMode`. Unlike
  /// `sortPriorityRank` (which mirrors `AgentStatus`'s own working > idle
  /// priority), this puts `idle` on top — an agent that's finished its turn
  /// and is awaiting you is what most needs your attention, more than one
  /// still churning away unattended. Stale/quiet still override to the
  /// bottom, same reasoning as `sortPriorityRank`/`displayGlyph`.
  var needsAttentionRank: Int {
    if isStale { return -2 }
    if isQuiet { return -1 }
    switch status {
    case .working: return 0
    case .idle: return 1
    }
  }
}
