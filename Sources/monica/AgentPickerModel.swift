import AppKit
import Foundation

/// Search + keyboard-navigation state for the menu bar popover's agent list.
/// Uses an AppKit local event monitor for arrow/return/escape because
/// SwiftUI's `.onKeyPress` doesn't reliably receive focus inside a popover's
/// text field — same reasoning as beacon's `PickerModel`.
///
/// Also drives "send a message without switching" (⌘Return), mirroring
/// `,tmux-ai-agents`'s `alt-enter` binding. While `composeTarget` is set, the
/// search field is replaced by a message field; plain Return sends and
/// Escape cancels back to search instead of closing the popover.
@MainActor
final class AgentPickerModel: ObservableObject {
  @Published var sessions: [AgentSession] = [] {
    didSet { updatePreview() }
  }
  @Published var selection = 0 {
    didSet { updatePreview() }
  }
  @Published var filterText: String = "" {
    didSet { filterChanged() }
  }

  /// The selected row's last message plus extra transcript context (git
  /// branch, model, last prompt, tool activity), read live from its
  /// transcript file — see `TranscriptPreview`. Recomputed on
  /// selection/list changes rather than cached, so it stays fresh while a
  /// row sits highlighted.
  @Published private(set) var previewDetails = TranscriptDetails()

  @Published var composeTarget: AgentSession?
  @Published var composeText: String = ""

  /// Height of the scrollable agent list, computed by `MenuBarController`
  /// from the active screen's height each time the popover opens (capped
  /// at 60% of it) rather than a small fixed value.
  @Published var listHeight: CGFloat = 150

  /// Bumped whenever the text field should (re-)claim keyboard focus.
  /// `@FocusState` set from `.onAppear` alone is a race against the
  /// popover's window actually becoming key — `MenuBarController` bumps
  /// this again once it has confirmed `makeKey()` happened.
  @Published var focusTick = 0
  func requestFocus() { focusTick += 1 }

  /// Swapping `composeTarget` swaps which `TextField` is in the view tree
  /// (search field <-> message field) — bumping focus in the *same* render
  /// pass as that swap races SwiftUI's diffing and can land on the field
  /// that's about to be removed. Deferring one run-loop tick lets the new
  /// field exist first.
  private func requestFocusNextTick() {
    DispatchQueue.main.async { [weak self] in self?.requestFocus() }
  }

  var filteredSessions: [AgentSession] {
    guard !filterText.isEmpty else { return sessions }
    return sessions.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(filterText)
        || $0.displaySubtitle.localizedCaseInsensitiveContains(filterText)
    }
  }

  /// The highlighted row, if any — what the preview panel is showing.
  var selectedSession: AgentSession? {
    let list = filteredSessions
    return list.indices.contains(selection) ? list[selection] : nil
  }

  var onCommit: ((AgentSession) -> Void)?
  var onSendMessage: ((AgentSession, String) -> Void)?
  var onCancel: (() -> Void)?

  nonisolated(unsafe) private var monitor: Any?

  func activate(sessions: [AgentSession]) {
    self.sessions = sessions
    selection = 0
    filterText = ""
    composeTarget = nil
    composeText = ""
    installMonitor()
  }

  func deactivate() {
    removeMonitor()
  }

  func move(_ delta: Int) {
    let list = filteredSessions
    guard !list.isEmpty else { return }
    selection = min(max(0, selection + delta), list.count - 1)
  }

  func choose(_ session: AgentSession) {
    if let idx = filteredSessions.firstIndex(of: session) {
      selection = idx
    }
    commit()
  }

  private func filterChanged() {
    let count = filteredSessions.count
    guard count > 0 else {
      selection = 0
      return
    }
    selection = min(selection, count - 1)
  }

  private func updatePreview() {
    let list = filteredSessions
    guard list.indices.contains(selection) else {
      previewDetails = TranscriptDetails()
      return
    }
    previewDetails = TranscriptPreview.details(for: list[selection])
  }

  private func commit() {
    let list = filteredSessions
    guard list.indices.contains(selection) else {
      cancel()
      return
    }
    onCommit?(list[selection])
  }

  private func cancel() {
    onCancel?()
  }

  private func beginCompose() {
    let list = filteredSessions
    guard list.indices.contains(selection) else { return }
    composeTarget = list[selection]
    composeText = ""
    requestFocusNextTick()
  }

  private func cancelCompose() {
    composeTarget = nil
    composeText = ""
    requestFocusNextTick()
  }

  private func sendComposedMessage() {
    guard let target = composeTarget else { return }
    let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      cancelCompose()
      return
    }
    onSendMessage?(target, text)
  }

  private func installMonitor() {
    removeMonitor()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      switch event.keyCode {
      case 126:  // up
        guard self.composeTarget == nil else { return event }
        self.move(-1)
        return nil
      case 125:  // down
        guard self.composeTarget == nil else { return event }
        self.move(1)
        return nil
      case 36, 76:  // return / enter
        if self.composeTarget != nil {
          self.sendComposedMessage()
        } else if event.modifierFlags.contains(.command) {
          self.beginCompose()
        } else {
          self.commit()
        }
        return nil
      case 53:  // escape
        if self.composeTarget != nil {
          self.cancelCompose()
        } else {
          self.cancel()
        }
        return nil
      default: return event
      }
    }
  }

  private func removeMonitor() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}
