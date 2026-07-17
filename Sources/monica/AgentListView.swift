import SwiftUI

/// A single agent row — status glyph, project/session title, window/agent
/// subtitle. Shared by the menu bar popover and the Spotlight popup.
struct AgentRowView: View {
    let session: AgentSession
    let isSelected: Bool

    private var glyphColor: Color {
        guard !session.isStale else { return .secondary }
        switch session.status {
        case .working: return .green
        case .waiting: return .yellow
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.displayGlyph)
                .foregroundColor(glyphColor)
                .frame(width: 14)
            Text(session.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(session.displaySubtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(session.lastUpdatedDisplay)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        // Matches `PopoverLayout.horizontalInset` so row text lines up with
        // the search field and preview panel above/below it — this used to
        // be a locally-hardcoded 10 here *plus* another 4 from the list's
        // own outer padding (14 total), visibly misaligned from those.
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
    }
}

/// One row's height including its vertical padding — used by
/// `MenuBarController` to size the list to its actual content rather than
/// always reserving max space.
let agentRowHeight: CGFloat = 26

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
            .padding(.vertical, 4)
        }
    }
}
