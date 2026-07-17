import SwiftUI

/// A single agent row — status glyph, project/session title, window/agent
/// subtitle. Shared by the menu bar popover and the Spotlight popup.
struct AgentRowView: View {
    let session: AgentSession
    let isSelected: Bool

    private var glyphColor: Color {
        switch session.status {
        case .working: return .green
        case .waiting: return .yellow
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.status.glyph)
                .foregroundColor(glyphColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(session.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(session.lastUpdatedDisplay)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
    }
}

/// The shared list body: an empty-state message, or one `AgentRowView` per
/// session with click-to-select.
struct AgentListView: View {
    let sessions: [AgentSession]
    var selection: Int = -1
    let onSelect: (AgentSession) -> Void

    var body: some View {
        if sessions.isEmpty {
            Text("No active AI agents")
                .foregroundColor(.secondary)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    AgentRowView(session: session, isSelected: index == selection)
                        .onTapGesture { onSelect(session) }
                }
            }
            .padding(4)
        }
    }
}
