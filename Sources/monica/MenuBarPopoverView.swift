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
        Text("↩ send · ⇧↩ newline · esc cancel")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
      // `axis: .vertical` lets the field grow for a multi-line message
      // (up to 5 lines before it scrolls internally) — plain Return still
      // sends via the keydown monitor in AgentPickerModel, which only lets
      // Return through to this field (rather than swallowing it) when
      // Shift is held, so Shift+Return is what actually reaches here to
      // insert a newline.
      TextField("Type a message…", text: $model.composeText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .lineLimit(1...5)
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
          onSelect: model.select,
          onCommit: model.choose,
          onSendMessage: model.composeMessage,
          onRequestKill: { model.pendingKillSession = $0 }
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
    // Shared across all rows rather than per-row @State, since a context
    // menu's Button closure has no view identity of its own to hang state
    // off of — `AgentPickerModel.pendingKillSession` is the single source
    // of truth for which row (if any) is mid-confirmation.
    .confirmationDialog(
      "Kill this pane?",
      isPresented: Binding(
        get: { model.pendingKillSession != nil },
        set: { if !$0 { model.pendingKillSession = nil } }
      ),
      presenting: model.pendingKillSession
    ) { session in
      Button("Kill Pane", role: .destructive) {
        Switcher.killPane(session)
        model.pendingKillSession = nil
      }
      Button("Cancel", role: .cancel) { model.pendingKillSession = nil }
    } message: { session in
      Text(
        "This ends the tmux pane running \(session.project) — the agent process will be terminated."
      )
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
  @ObservedObject private var settings = AppSettings.shared

  private var details: TranscriptDetails { model.previewDetails }

  /// Inner padding of the preview card; the text's fixed wrapping width
  /// below must subtract it from both sides.
  private static let cardPadding: CGFloat = 8

  /// True once at least one enabled detail toggle actually has data to
  /// show — keeps the chip row from reserving space when nothing's there
  /// (e.g. every pi session, which never has a git branch). Tool activity
  /// gets its own line (like "You:") rather than a chip — see below.
  private var showsMetaRow: Bool {
    (settings.previewShowGitBranch && details.gitBranch != nil)
      || (settings.previewShowModel && details.model != nil)
  }

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
        if details.text != nil {
          Button(action: model.copyPreviewToPasteboard) {
            Image(systemName: "doc.on.doc")
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .help("Copy last message (⌘⇧C)")
        }
      }

      if showsMetaRow {
        // Horizontally scrollable rather than wrapping, so a long tool
        // summary or model name can't blow out the popover's fixed
        // width — same reasoning as the ScrollView-based clamping used
        // elsewhere in this file.
        ScrollView(.horizontal, showsIndicators: false) {
          MetaChipsRow(details: details, settings: settings)
        }
      }

      if settings.previewShowToolActivity, let tool = details.toolActivity {
        HStack(alignment: .top, spacing: 4) {
          Text("Tool:")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
          Text(tool)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      if settings.previewShowLastPrompt, let prompt = details.lastPrompt, !prompt.isEmpty {
        HStack(alignment: .top, spacing: 4) {
          Text("You:")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
          Text(prompt)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      ScrollView {
        MarkdownPreviewText(
          raw: details.text ?? "No agent selected"
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

/// A single small pill in the preview panel's meta row (git branch, model,
/// or tool activity) — same visual language as `AgentBadge` but generic and
/// icon-led rather than agent-tinted.
private struct MetaChip: View {
  let systemImage: String
  let text: String

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: systemImage)
        .font(.system(size: 8))
      Text(text)
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 5)
    .padding(.vertical, 1)
    .background(Capsule().fill(Color.secondary.opacity(0.12)))
  }
}

/// Git branch / model, each independently toggleable from Settings and each
/// only shown when the transcript actually had that field. Tool activity has
/// its own line further down (see `LastMessageSection`), not a chip here.
private struct MetaChipsRow: View {
  let details: TranscriptDetails
  @ObservedObject var settings: AppSettings

  var body: some View {
    HStack(spacing: 5) {
      if settings.previewShowGitBranch, let branch = details.gitBranch {
        MetaChip(systemImage: "arrow.triangle.branch", text: branch)
      }
      if settings.previewShowModel, let model = details.model {
        MetaChip(systemImage: "cpu", text: model)
      }
    }
  }
}

private struct FooterSection: View {
  @ObservedObject var model: AgentPickerModel
  let onSettings: () -> Void
  let onQuit: () -> Void

  private struct StatusChip {
    let label: String
    /// The status word to filter by when tapped, matching
    /// `StatusStyle.word(for:isStale:isQuiet:)` — reuses the existing
    /// (previously undiscoverable) "type a status word to filter" behavior
    /// in `AgentPickerModel.filteredSessions`. `nil` means "show all",
    /// used by the trailing "N agents" segment.
    let filterWord: String?
  }

  /// "2 working · 1 waiting · 4 agents" as individually tappable segments —
  /// always sums over *all* agents, not the filtered list, so it stays a
  /// status readout rather than a search-result count (the search field
  /// already shows that).
  private var chips: [StatusChip] {
    let sessions = model.sessions
    guard !sessions.isEmpty else { return [StatusChip(label: "No agents", filterWord: nil)] }
    var result: [StatusChip] = []
    let working = sessions.filter { $0.status == .working && !$0.isStale && !$0.isQuiet }.count
    let waiting = sessions.filter { $0.status == .waiting && !$0.isStale && !$0.isQuiet }.count
    if working > 0 {
      result.append(StatusChip(label: "\(working) working", filterWord: "working"))
    }
    if waiting > 0 {
      result.append(StatusChip(label: "\(waiting) waiting", filterWord: "waiting"))
    }
    if result.isEmpty { result.append(StatusChip(label: "all idle", filterWord: "idle")) }
    result.append(
      StatusChip(
        label: "\(sessions.count) agent\(sessions.count == 1 ? "" : "s")", filterWord: nil))
    return result
  }

  /// Tapping the already-active chip clears the filter (toggle); tapping a
  /// different one replaces it. The "N agents"/"No agents" chip (nil
  /// `filterWord`) always clears, acting as a "show all" reset.
  private func tap(_ chip: StatusChip) {
    guard let word = chip.filterWord else {
      model.filterText = ""
      return
    }
    if model.filterText.caseInsensitiveCompare(word) == .orderedSame {
      model.filterText = ""
    } else {
      model.filterText = word
      model.requestFocus()
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      HStack(spacing: 4) {
        ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
          if index > 0 {
            Text("·").foregroundStyle(.tertiary)
          }
          StatusChipText(label: chip.label) { tap(chip) }
        }
      }
      .font(.system(size: 11))
      .lineLimit(1)
      Spacer(minLength: 8)
      FooterIconButton(systemImage: "gearshape", help: "Settings", action: onSettings)
      FooterIconButton(systemImage: "power", help: "Quit Monica", action: onQuit)
    }
    .popoverSection(vertical: 7)
  }
}

/// A single tappable footer summary segment — underlines and brightens on
/// hover so it reads as interactive despite being plain `Text`, matching
/// `FooterIconButton`'s hover language without needing a button background
/// (which would look too heavy inline with prose).
private struct StatusChipText: View {
  let label: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Text(label)
      .foregroundStyle(hovering ? .primary : .secondary)
      .underline(hovering)
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .onHover { hovering = $0 }
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
