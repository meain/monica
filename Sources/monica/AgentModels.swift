import Foundation

/// Three live states: `working` (Claude Code's `busy`), `waiting` (blocked
/// mid-task on a permission prompt/dialog — Claude Code's own `waiting`,
/// with a `waitingFor` reason; claude only, pi has no reliable signal for
/// it), and `idle` (everything else — finished its turn, awaiting you).
/// Staleness (see `AgentSession.isQuiet`/`isStale`) is a separate time-based
/// overlay, not a status value — and never applies to `waiting`.
enum AgentStatus: String, Comparable {
  case idle
  case working
  case waiting

  /// waiting > working > idle.
  private var priority: Int {
    switch self {
    case .idle: return 0
    case .working: return 1
    case .waiting: return 2
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
    // Not ▲ — too easily mistaken for ▶ at menu bar size. Covered by Menlo
    // (checked with CTFontCreateForString, see AGENTS.md's glyph gotcha).
    case .waiting: return "◆"
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
  /// Why a `.waiting` agent is blocked, verbatim from Claude Code's registry
  /// (e.g. "input needed", "dialog open", "sandbox request"). Internal to
  /// Claude Code and may change between versions — display only, never
  /// branch on it. Nil for every other status.
  var waitingFor: String? = nil

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
  ///
  /// Never true for `.waiting`: the registry only writes on a status change,
  /// so an agent left blocked on a prompt for hours has an old timestamp but
  /// is exactly as blocked as it was — decaying it to stale would hide the
  /// one agent that most needs you.
  var isStale: Bool {
    if status == .waiting { return false }
    guard let lastUpdated else { return true }
    return Date().timeIntervalSince(lastUpdated) > AgentSession.staleThreshold
  }

  /// True for the 15m-3h window between a normal update and going fully
  /// `isStale` — the status file hasn't been touched in a while but isn't
  /// old enough yet to distrust entirely. Doesn't change `status` itself,
  /// just how it's drawn (see `displayGlyph`). Never true for `.waiting`,
  /// same reason as `isStale`.
  var isQuiet: Bool {
    if status == .waiting { return false }
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

  /// Used by the scanner's `.statusPriority` `SortMode` — higher
  /// sorts first. Stale/quiet always sink below every real status
  /// (regardless of what `status` itself says, same as `displayGlyph`),
  /// since they're more likely a dead/uncertain session than one actually
  /// wanting attention; within "real" statuses this reuses `AgentStatus`'s
  /// own `waiting > working > idle` priority. Sorted descending, this yields
  /// waiting → working → idle → quiet → stale.
  var sortPriorityRank: Int {
    if isStale { return -2 }
    if isQuiet { return -1 }
    switch status {
    case .idle: return 0
    case .working: return 1
    case .waiting: return 2
    }
  }

  /// Used by the scanner's `.needsAttention` `SortMode`. Unlike
  /// `sortPriorityRank` (which mirrors `AgentStatus`'s own working > idle
  /// priority), this puts agents awaiting you on top — blocked on a prompt
  /// first (it can't make progress at all until you act), then finished its
  /// turn — ahead of ones still churning away unattended. Stale/quiet still
  /// override to the bottom, same reasoning as `sortPriorityRank`/`displayGlyph`.
  var needsAttentionRank: Int {
    if isStale { return -2 }
    if isQuiet { return -1 }
    switch status {
    case .working: return 0
    case .idle: return 1
    case .waiting: return 2
    }
  }

  /// Blocked on you or finished and awaiting you — what the jump hotkey
  /// cycles through and what notifications fire for.
  var isAwaitingUser: Bool { needsAttentionRank >= 1 }

  var inboxSection: InboxSection {
    if status == .waiting { return .needsYou }
    if isStale || isQuiet { return .quiet }
    return status == .working ? .working : .finished
  }
}

/// The popover list's grouping, in display order: what needs you first,
/// then what finished and is awaiting you, then what's still running, then
/// quiet/stale sessions as a compact tail. Only the popover groups this way
/// — the menu bar strip keeps the scanner's `SortMode` order, since that's
/// how glyphs map to tmux positions at a glance.
enum InboxSection: Int, CaseIterable {
  case needsYou
  case finished
  case working
  case quiet

  var title: String {
    switch self {
    case .needsYou: return "NEEDS YOU"
    case .finished: return "FINISHED"
    case .working: return "WORKING"
    case .quiet: return "QUIET"
    }
  }
}
