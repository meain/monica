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
    // Orange, not yellow — yellow washes out against the light menu bar.
    case .waiting: return .orange
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
/// working (so it reads as "live" at a glance), a filled orange diamond for
/// waiting (blocked on you), a hollow ring for idle, a filled gray dot once
/// quiet (15m-3h since the last status update), and a dashed ring for stale
/// — the same shape language as the menu bar glyphs (▶ ◆ ○ ● ◌) without
/// mixing text glyphs into the rows.
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
        case .waiting:
          Rectangle()
            .fill(color)
            .rotationEffect(.degrees(45))
            .scaleEffect(0.8)
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

/// Flattens a markdown message into a single plain line for the card
/// snippet: drops heading/list/quote markers and inline markup, joins lines.
/// `TranscriptPreview`'s parenthesized placeholders ("(preview unavailable)")
/// are dropped rather than shown as if the agent had said them.
func snippetLine(_ raw: String?) -> String? {
  guard let raw, !(raw.hasPrefix("(") && raw.hasSuffix(")")) else { return nil }
  let lines = raw.split(whereSeparator: \.isNewline).map { line -> String in
    var s = line.trimmingCharacters(in: .whitespaces)
    while let first = s.first, "#>-*+".contains(first) { s.removeFirst() }
    return s.trimmingCharacters(in: .whitespaces)
  }
  let joined = lines.filter { !$0.isEmpty && !$0.hasPrefix("```") }.joined(separator: " ")
    .replacingOccurrences(of: "**", with: "")
    .replacingOccurrences(of: "`", with: "")
  return joined.isEmpty ? nil : joined
}

/// An inbox card for a waiting/finished/working agent: status, name, tmux
/// location, badge and age on the first line, the last message as a snippet
/// under it (one line, three when selected). A selected waiting card also
/// gets Reply/Jump buttons, since acting on it is the whole point.
struct InboxCardRow: View {
  let session: AgentSession
  let snippet: String?
  let isSelected: Bool
  var onReply: () -> Void = {}
  var onJump: () -> Void = {}
  @State private var isHovering = false

  private var isWaiting: Bool { session.status == .waiting }
  private let waitingColor = StatusStyle.color(for: .waiting, isStale: false, isQuiet: false)

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 7) {
        StatusIndicator(status: session.status, isStale: session.isStale, isQuiet: session.isQuiet)
        Text(session.displayName)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
          .layoutPriority(1)
        Text("\(session.session) · \(session.windowName)")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 6)
        AgentBadge(agentName: session.agentName)
        Text(session.lastUpdatedDisplay)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .frame(width: 44, alignment: .trailing)
      }
      if let snippet {
        Text(snippet)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(isSelected ? 3 : 1)
          .padding(.leading, 15)
      }
      if isWaiting {
        HStack(spacing: 6) {
          Text(session.waitingFor ?? "blocked")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(waitingColor)
            .lineLimit(1)
          Spacer(minLength: 6)
          if isSelected {
            InboxActionButton(title: "Reply ⌘↩", filled: false, action: onReply)
            InboxActionButton(title: "Jump ↩", filled: true, action: onJump)
          }
        }
        .padding(.leading, 15)
        .padding(.top, isSelected ? 3 : 0)
      }
    }
    // Full `horizontalInset` inside and none outside: the card's edge
    // lines up with the other cards' edges, its text with their text.
    .padding(.horizontal, PopoverLayout.horizontalInset)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: PopoverLayout.innerCornerRadius + 2)
        .fill(
          isWaiting
            ? waitingColor.opacity(isHovering || isSelected ? 0.16 : 0.1)
            : Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.8 : 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    )
    .overlay(
      // `strokeBorder`, not `stroke`: the card runs to the ScrollView's
      // edge, which would clip the outer half of a centered stroke.
      RoundedRectangle(cornerRadius: PopoverLayout.innerCornerRadius + 2)
        .strokeBorder(
          isSelected
            ? (isWaiting ? waitingColor : Color.accentColor)
            : (isWaiting ? waitingColor.opacity(0.35) : Color.primary.opacity(0.06)),
          lineWidth: isSelected ? 1.5 : 1)
    )
    .contentShape(Rectangle())
    .help("\(session.displayTitle) — \(session.displaySubtitle)\n\(session.panePath)")
    .onHover { isHovering = $0 }
  }
}

private struct InboxActionButton: View {
  let title: String
  let filled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(filled ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(filled ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(filled ? Color.clear : Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }
}

/// Quiet/stale sessions collapse to a single muted line — they're the
/// low-noise tail of the inbox, not something to read.
struct InboxQuietRow: View {
  let session: AgentSession
  let isSelected: Bool
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 7) {
      StatusIndicator(status: session.status, isStale: session.isStale, isQuiet: session.isQuiet)
      Text(session.displayName)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .layoutPriority(1)
      Text("\(session.session) · \(session.windowName)")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      Spacer(minLength: 6)
      AgentBadge(agentName: session.agentName)
      Text(session.lastUpdatedDisplay)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(width: 44, alignment: .trailing)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, PopoverLayout.rowInnerInset)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: PopoverLayout.innerCornerRadius)
        .fill(
          isSelected
            ? Color.accentColor.opacity(0.2)
            : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
    )
    .padding(.horizontal, PopoverLayout.rowOuterInset)
    .contentShape(Rectangle())
    .help("\(session.displayTitle) — \(session.displaySubtitle)\n\(session.panePath)")
    .onHover { isHovering = $0 }
  }
}

private struct InboxSectionHeader: View {
  let section: InboxSection
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      Text(section.title)
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
      if section == .needsYou {
        Text("\(count)")
          .font(.system(size: 9.5, weight: .bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .background(
            Capsule().fill(StatusStyle.color(for: .waiting, isStale: false, isQuiet: false)))
      }
    }
    .padding(.horizontal, PopoverLayout.horizontalInset)
    .padding(.top, 6)
    .padding(.bottom, 1)
  }
}

/// Rough per-element heights for sizing the list's `ScrollView` to its
/// content (`MenuBarController.resizeForScreen`) — rows vary in height now,
/// so this replaces a flat row-count × row-height. `NSPopover.contentSize`
/// is only a hint anyway (see AGENTS.md); overshooting a little just leaves
/// air at the bottom, undershooting makes the list scroll.
enum InboxMetrics {
  static let sectionHeader: CGFloat = 22
  static let card: CGFloat = 47
  static let quietRow: CGFloat = 26
  /// The selected card's extra snippet lines, or a waiting card's buttons.
  static let selectionExtra: CGFloat = 34
  static let rowSpacing: CGFloat = 4

  static func listHeight(for sessions: [AgentSession]) -> CGFloat {
    guard !sessions.isEmpty else { return emptyListHeight }
    let sections = Set(sessions.map(\.inboxSection)).count
    let rows = sessions.reduce(CGFloat(0)) {
      $0 + ($1.inboxSection == .quiet ? quietRow : card) + rowSpacing
    }
    return CGFloat(sections) * sectionHeader + rows + selectionExtra + 8
  }
}

/// Height reserved for the empty-state placeholder when there are no rows.
let emptyListHeight: CGFloat = 96

/// The shared list body: an empty-state placeholder, or the sessions grouped
/// into `InboxSection`s with a header each. `sessions` must already be in
/// section order (`AgentPickerModel.filteredSessions` is) — this only draws a
/// header wherever the section changes. Hovering previews (mirroring
/// arrow-key navigation), a click commits immediately (mirroring Return).
struct AgentListView: View {
  let sessions: [AgentSession]
  var selection: Int = -1
  /// True when the list is empty *because of the filter text*, not because
  /// no agents are running — the two deserve different placeholders.
  var isFiltering: Bool = false
  var snippet: (AgentSession) -> String? = { _ in nil }
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
      VStack(alignment: .leading, spacing: InboxMetrics.rowSpacing) {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
          if index == 0 || sessions[index - 1].inboxSection != session.inboxSection {
            InboxSectionHeader(
              section: session.inboxSection,
              count: sessions.filter { $0.inboxSection == session.inboxSection }.count)
          }
          row(session, isSelected: index == selection)
            .onHover { if $0 { onSelect(session) } }
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

  @ViewBuilder
  private func row(_ session: AgentSession, isSelected: Bool) -> some View {
    if session.inboxSection == .quiet {
      InboxQuietRow(session: session, isSelected: isSelected)
    } else {
      InboxCardRow(
        session: session, snippet: snippetLine(snippet(session)), isSelected: isSelected,
        onReply: { onSendMessage(session) }, onJump: { onCommit(session) })
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
