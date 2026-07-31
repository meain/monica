import AppKit
import SwiftUI

/// Colors shared between the agent rows, the preview header, and the
/// Settings legend, so a status never renders in two slightly different
/// shades in different places.
enum StatusStyle {
  static func color(for status: AgentStatus, isStale: Bool, isQuiet: Bool) -> Color {
    guard !isStale, !isQuiet else { return .secondary }
    switch status {
    case .working: return .green
    case .idle: return .secondary
    }
  }

  static func word(for status: AgentStatus, isStale: Bool, isQuiet: Bool) -> String {
    if isStale { return "stale" }
    if isQuiet { return "quiet" }
    return status.rawValue
  }

  /// Per-agent tint for the small name badge: claude is orange (its brand
  /// color), pi purple, anything unknown gray.
  static func agentTint(_ agentName: String) -> Color {
    switch agentName {
    case "claude": return .orange
    case "pi": return .purple
    default: return .secondary
    }
  }
}

/// The row's leading status indicator: a filled dot with a soft glow for
/// working (so it reads as "live" at a glance), a hollow ring for idle, a
/// filled gray dot once quiet (15m-3h since the last status update), and a
/// dashed ring for stale — the same shape language as the menu bar glyphs
/// (▶ ○ ● ◌) without mixing text glyphs into the rows.
struct StatusIndicator: View {
  let status: AgentStatus
  let isStale: Bool
  let isQuiet: Bool

  private var color: Color {
    StatusStyle.color(for: status, isStale: isStale, isQuiet: isQuiet)
  }

  var body: some View {
    ZStack {
      if isStale {
        Circle()
          .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2]))
      } else if isQuiet {
        Circle()
          .fill(color)
      } else {
        switch status {
        case .working:
          Circle()
            .fill(color)
            .shadow(color: color.opacity(0.7), radius: 3)
        case .idle:
          Circle()
            .strokeBorder(color, lineWidth: 1.5)
        }
      }
    }
    .frame(width: 8, height: 8)
  }
}

/// Tiny tag naming which agent runs in the pane ("claude"/"pi"), tinted per
/// agent so the two kinds are tellable apart without reading. Monospaced and
/// squared-off (rather than a capsule) so it reads as a technical identifier
/// tag rather than a soft pill — matches the tmux/CLI-adjacent nature of
/// what it's labeling.
struct AgentBadge: View {
  let agentName: String

  var body: some View {
    Text(agentName)
      .font(.system(size: 9, weight: .medium, design: .monospaced))
      .foregroundStyle(StatusStyle.agentTint(agentName))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(StatusStyle.agentTint(agentName).opacity(0.14))
      )
  }
}

/// A single-line agent row — status dot, project (bold) with session ·
/// window after it, then agent badge and relative time on the right.
struct AgentRowView: View {
  let session: AgentSession
  let isSelected: Bool
  /// Fires on hover enter/exit — the list uses this to drive the preview
  /// panel (mouse users get a live preview by hovering, mirroring arrow-key
  /// navigation), while click keeps its original single-action behavior of
  /// committing immediately.
  var onHoverChanged: (Bool) -> Void = { _ in }
  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      StatusIndicator(status: session.status, isStale: session.isStale, isQuiet: session.isQuiet)
      Text(session.displayName)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Text("\(session.session) · \(session.windowName)")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      AgentBadge(agentName: session.agentName)
      Text(session.lastUpdatedDisplay)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(width: 44, alignment: .trailing)
    }
    // Inner + outer padding sum to `PopoverLayout.horizontalInset`, so
    // the row text lines up with the search field and preview panel
    // while the selection background stays inset from the popover edge
    // like a native menu highlight — see `PopoverLayout`'s doc comment
    // for why this must route through the shared constants.
    .padding(.horizontal, PopoverLayout.rowInnerInset)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: PopoverLayout.innerCornerRadius)
        .fill(
          isSelected
            ? Color.accentColor.opacity(0.2)
            : (isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: PopoverLayout.innerCornerRadius)
            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    )
    .padding(.horizontal, PopoverLayout.rowOuterInset)
    .contentShape(Rectangle())
    // Row text truncates (`lineLimit(1)` on project/session/window above);
    // the tooltip carries the untruncated names plus the working directory
    // so a long project name is never fully hidden. When a custom name is
    // set it replaces the project in the row, so the tooltip (which keeps
    // `displayTitle`'s real project) is also where the underlying project
    // stays discoverable.
    .help("\(session.displayTitle) — \(session.displaySubtitle)\n\(session.panePath)")
    .onHover { hovering in
      isHovering = hovering
      onHoverChanged(hovering)
    }
  }
}

/// One row's height including the list's inter-row spacing — used by
/// `MenuBarController` to size the list to its actual content rather than
/// always reserving max space.
let agentRowHeight: CGFloat = 28

/// Height reserved for the empty-state placeholder when there are no rows.
let emptyListHeight: CGFloat = 96

/// The shared list body: an empty-state placeholder, or one `AgentRowView`
/// per session — hovering previews (mirroring arrow-key navigation), a
/// click commits immediately (mirroring Return).
struct AgentListView: View {
  let sessions: [AgentSession]
  var selection: Int = -1
  /// True when the list is empty *because of the filter text*, not because
  /// no agents are running — the two deserve different placeholders.
  var isFiltering: Bool = false
  /// Hover: select + preview only, mirroring arrow-key navigation.
  let onSelect: (AgentSession) -> Void
  /// Click: commit (switch tmux to this pane), mirroring Return.
  var onCommit: (AgentSession) -> Void = { _ in }
  /// Context menu "Send Message…" — enters compose mode for this row.
  var onSendMessage: (AgentSession) -> Void = { _ in }
  /// Context menu "Rename…" — enters rename mode for this row (⌘R does the
  /// same for the selected row).
  var onRename: (AgentSession) -> Void = { _ in }
  /// Context menu "Kill Pane…" — the caller owns the confirmation step.
  var onRequestKill: (AgentSession) -> Void = { _ in }

  var body: some View {
    if sessions.isEmpty {
      VStack(spacing: 5) {
        Image(systemName: isFiltering ? "magnifyingglass" : "moon.zzz")
          .font(.system(size: 20))
          .foregroundStyle(.tertiary)
        Text(isFiltering ? "No matching agents" : "No active agents")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        if !isFiltering {
          Text("Start claude or pi inside a tmux pane")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, minHeight: emptyListHeight)
    } else {
      VStack(spacing: 2) {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
          AgentRowView(
            session: session, isSelected: index == selection,
            onHoverChanged: { hovering in
              if hovering { onSelect(session) }
            }
          )
          .onTapGesture { onCommit(session) }
          .contextMenu {
            Button("Switch to Pane") { onCommit(session) }
            Button("Send Message…") { onSendMessage(session) }
            Button("Rename…") { onRename(session) }
            Divider()
            Button("Copy Path") { copyToPasteboard(session.panePath) }
            Button("Reveal in Finder") {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.panePath)
            }
            Button("Copy Last Message") { copyLastMessage(of: session) }
            Divider()
            Button("Kill Pane…", role: .destructive) { onRequestKill(session) }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }
}

private func copyToPasteboard(_ text: String) {
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
}

/// Reads the row's transcript directly rather than relying on
/// `AgentPickerModel.previewDetails`, since a context-menu action can
/// target a row other than the currently-selected/previewed one.
private func copyLastMessage(of session: AgentSession) {
  if let text = TranscriptPreview.details(for: session).text {
    copyToPasteboard(text)
  }
}
