import SwiftUI

/// The menu bar popover's SwiftUI content, decomposed into one section per
/// row of the layout diagram in DESIGN.md. `MenuBarController` owns the
/// `NSPopover`/`NSStatusItem` mechanics; this file owns everything visual.
struct MenuBarPopoverView: View {
  @ObservedObject var model: AgentPickerModel
  let onSettings: () -> Void
  let onQuit: () -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.composeTarget != nil {
        ComposeFieldSection(model: model, isFocused: $searchFocused)
      } else {
        SearchFieldSection(model: model, isFocused: $searchFocused)
      }

      Divider()

      AgentListSection(model: model)

      if model.composeTarget == nil {
        Divider()
        LastMessageSection(model: model)
      }

      Divider()

      FooterSection(model: model, onSettings: onSettings, onQuit: onQuit)
    }
    .frame(width: PopoverLayout.width)
    .onAppear { searchFocused = true }
    .onChange(of: model.focusTick) { searchFocused = true }
  }
}

private struct SearchFieldSection: View {
  @ObservedObject var model: AgentPickerModel
  var isFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextField("Search agents…", text: $model.filterText)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused(isFocused)
      if !model.filteredSessions.isEmpty {
        Text("\(model.filteredSessions.count)")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
    }
    .popoverSection(vertical: 9)
  }
}

private struct ComposeFieldSection: View {
  @ObservedObject var model: AgentPickerModel
  var isFocused: FocusState<Bool>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 10))
          .foregroundStyle(Color.accentColor)
        if let target = model.composeTarget {
          Text("Send to \(target.project)")
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        Text("↩ send · esc cancel")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
      TextField("Type a message…", text: $model.composeText)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused(isFocused)
    }
    .popoverSection(vertical: 8)
    // Applied outside `popoverSection()` so the tint bleeds to the
    // popover edges — a full-width banner that makes compose mode
    // unmistakably a different state from search.
    .background(Color.accentColor.opacity(0.07))
  }
}

private struct AgentListSection: View {
  @ObservedObject var model: AgentPickerModel

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        AgentListView(
          sessions: model.filteredSessions,
          selection: model.selection,
          isFiltering: !model.filterText.isEmpty,
          onSelect: model.choose
        )
        // See `ScrollbarSuppressor`'s doc comment: `.scrollIndicators
        // (.hidden)` below doesn't override AppKit's classic
        // `NSScroller`, which still draws (and reserves width) once
        // content actually overflows under a non-overlay system
        // scrollbar setting. This reaches the real `NSScrollView`
        // backing this `ScrollView` and disables its scroller
        // directly, which is the authoritative setting.
        .background(ScrollbarSuppressor())
      }
      // A `maxHeight` alone reports zero ideal height to the hosting
      // popover — same ScrollView gotcha noted in AGENTS.md. Use a
      // real height instead — `MenuBarController` computes this from
      // the screen size (up to 60% of it) each time the popover
      // opens, rather than a small fixed value.
      .frame(height: model.listHeight)
      // A non-overlay scrollbar (depends on the user's system-wide
      // "Show scroll bars" setting) reserves width inside the
      // ScrollView, shrinking the content area and shifting things
      // when it appears/disappears. Hidden here since the list is
      // still fully scrollable via trackpad/arrow keys without it.
      .scrollIndicators(.hidden)
      .onChange(of: model.selection) { scrollToSelection(proxy) }
    }
  }

  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    let list = model.filteredSessions
    guard list.indices.contains(model.selection) else { return }
    withAnimation { proxy.scrollTo(list[model.selection].id, anchor: .center) }
  }
}

private struct LastMessageSection: View {
  @ObservedObject var model: AgentPickerModel

  /// Inner padding of the preview card; the text's fixed wrapping width
  /// below must subtract it from both sides.
  private static let cardPadding: CGFloat = 8

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text("LAST MESSAGE")
          .font(.system(size: 9, weight: .semibold))
          .tracking(0.6)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        if let selected = model.selectedSession {
          Text(selected.project)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      ScrollView {
        MarkdownPreviewText(
          raw: model.previewText.isEmpty ? "No agent selected" : model.previewText
        )
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        // `ScrollView` doesn't reliably constrain a `Text`'s
        // wrapping width from `maxWidth: .infinity` alone — it
        // can propose an unbounded width, so the text stays on
        // one line and blows out the popover's overall width. A
        // genuine fixed width forces real wrapping.
        .frame(
          width: PopoverLayout.contentWidth - Self.cardPadding * 2,
          alignment: .leading
        )
        .textSelection(.enabled)
        // This is the panel where the scrollbar thumb was
        // actually confirmed visible via a real screenshot
        // despite `.scrollIndicators(.hidden)` below — see
        // `ScrollbarSuppressor`'s doc comment for why.
        .background(ScrollbarSuppressor())
        .padding(Self.cardPadding)
      }
      .frame(height: 96)
      .scrollIndicators(.hidden)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(Color(nsColor: .quaternarySystemFill))
      )
    }
    .popoverSection()
  }
}

private struct FooterSection: View {
  @ObservedObject var model: AgentPickerModel
  let onSettings: () -> Void
  let onQuit: () -> Void

  /// "2 working · 1 waiting · 4 agents" — always sums over *all* agents,
  /// not the filtered list, so it stays a status readout rather than a
  /// search-result count (the search field already shows that).
  private var summary: String {
    let sessions = model.sessions
    guard !sessions.isEmpty else { return "No agents" }
    var parts: [String] = []
    let working = sessions.filter { $0.status == .working && !$0.isStale }.count
    let waiting = sessions.filter { $0.status == .waiting && !$0.isStale }.count
    if working > 0 { parts.append("\(working) working") }
    if waiting > 0 { parts.append("\(waiting) waiting") }
    if parts.isEmpty { parts.append("all idle") }
    parts.append("\(sessions.count) agent\(sessions.count == 1 ? "" : "s")")
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 4) {
      Text(summary)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      FooterIconButton(systemImage: "gearshape", help: "Settings", action: onSettings)
      FooterIconButton(systemImage: "power", help: "Quit Monica", action: onQuit)
    }
    .popoverSection(vertical: 7)
  }
}

private struct FooterIconButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12))
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.secondary.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
  }
}
