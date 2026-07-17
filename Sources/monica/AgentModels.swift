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
}
