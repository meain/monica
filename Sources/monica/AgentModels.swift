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

    var id: String { paneId }

    var displayTitle: String { "\(session)/\(project)" }
    var displaySubtitle: String { "\(windowName) · \(agentName)" }
}
