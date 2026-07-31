import Carbon.HIToolbox
import Foundation

/// How `AgentScanner.scan()` orders `sessions` — read fresh on every scan, so
/// changing it in Settings takes effect on the next scan tick (or
/// immediately on next popover open, which scans synchronously). Purely an
/// initial-order concern: `AgentPickerModel.refreshData`'s "keep existing
/// rows stable while the popover is open" behavior is unaffected either way.
///
/// Declaration order is display order in Settings' picker — `.recency` is
/// listed first (it's the original/previous default) with a divider after
/// it, then the rest starting with `.statusPriority`, which is now the
/// actual default (see `AppSettings.init`).
enum SortMode: String, CaseIterable, Identifiable {
  case recency
  case statusPriority
  case stalestFirst
  case alphabeticalProject
  case groupedBySession
  case groupedByAgentType
  case tmux
  case needsAttention
  case yourActivity

  var id: String { rawValue }

  var label: String {
    switch self {
    case .recency: return "Recency"
    case .statusPriority: return "Status"
    case .stalestFirst: return "Stalest first"
    case .alphabeticalProject: return "Project (A–Z)"
    case .groupedBySession: return "Session"
    case .groupedByAgentType: return "Agent type"
    case .tmux: return "Tmux order"
    case .needsAttention: return "Needs attention"
    case .yourActivity: return "Recently switched to"
    }
  }

  /// Shown as the picker's footer — the modes answer different "which
  /// agent first" questions, not just cosmetic reorderings, so this is
  /// worth spelling out per-mode rather than one generic caption.
  var detail: String {
    switch self {
    case .recency:
      return "Whichever agent posted a status update most recently."
    case .statusPriority:
      return
        "Working agents first, then idle. Quiet/stale agents always sink to the bottom."
    case .stalestFirst:
      return "The agent you haven't checked on in the longest — the inverse of Recency."
    case .alphabeticalProject:
      return "By project name, A–Z. A fixed order that doesn't reshuffle as agents post updates."
    case .groupedBySession:
      return "Grouped by tmux session, then window."
    case .groupedByAgentType:
      return "Grouped by agent (claude, then pi)."
    case .tmux:
      return
        "Your current tmux session first, in window/pane order, then other sessions in the "
        + "order you last attached to them."
    case .needsAttention:
      return
        "Idle agents first — the ones finished and awaiting you, longest-idle first (most "
        + "overdue for a response) — then working agents. Quiet/stale sink to the bottom."
    case .yourActivity:
      return
        "Whichever agent you personally switched to most recently, regardless of its own activity."
    }
  }
}

/// UserDefaults-backed settings, edited from the Settings window and shared
/// with the menu bar popover / global hotkey.
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  private enum Keys {
    static let targetApp = "monica.targetApp"
    static let pollInterval = "monica.pollInterval"
    static let hotKeyCode = "monica.hotKeyCode"
    static let hotKeyModifiers = "monica.hotKeyModifiers"
    static let jumpHotKeyCode = "monica.jumpHotKeyCode"
    static let jumpHotKeyModifiers = "monica.jumpHotKeyModifiers"
    static let previewShowGitBranch = "monica.previewShowGitBranch"
    static let previewShowModel = "monica.previewShowModel"
    static let previewShowLastPrompt = "monica.previewShowLastPrompt"
    static let previewShowToolActivity = "monica.previewShowToolActivity"
    static let sortMode = "monica.sortMode"
  }

  /// The app name passed to `open -a <targetApp>` when switching. Ghostty by
  /// default, but configurable in Settings since the switch target is meant
  /// to be swappable.
  @Published var targetApp: String {
    didSet { UserDefaults.standard.set(targetApp, forKey: Keys.targetApp) }
  }

  @Published var pollInterval: TimeInterval {
    didSet { UserDefaults.standard.set(pollInterval, forKey: Keys.pollInterval) }
  }

  /// Default ⌃⌥⇧A. Deliberately *not* ⌃⌥⌘ ("hyper") + a letter — that
  /// modifier combo is the user's Hammerspoon prefix, so every letter under
  /// it is likely already claimed there, which silently blocks
  /// RegisterEventHotKey (no error, the hotkey just never fires).
  @Published var hotKeyCode: UInt32 {
    didSet { UserDefaults.standard.set(hotKeyCode, forKey: Keys.hotKeyCode) }
  }

  @Published var hotKeyModifiers: UInt32 {
    didSet { UserDefaults.standard.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers) }
  }

  /// Not persisted — recomputed every time `AppDelegate` (re-)registers the
  /// hotkey with Carbon. True means `RegisterEventHotKey` failed, almost
  /// always because the chord is already claimed by another app (see
  /// `HotKeyManager.register`'s doc comment). Settings shows a warning when
  /// this is true instead of leaving a dead hotkey undiagnosed.
  @Published var hotKeyRegistrationFailed: Bool = false

  /// A second, independent global hotkey that jumps straight to the next
  /// `.idle` agent (cycling on repeated presses) without opening the
  /// popover at all — default ⌃⌥⇧W, same reasoning as `hotKeyCode`'s doc
  /// comment for avoiding the Hammerspoon hyper-key prefix.
  @Published var jumpHotKeyCode: UInt32 {
    didSet { UserDefaults.standard.set(jumpHotKeyCode, forKey: Keys.jumpHotKeyCode) }
  }

  @Published var jumpHotKeyModifiers: UInt32 {
    didSet { UserDefaults.standard.set(jumpHotKeyModifiers, forKey: Keys.jumpHotKeyModifiers) }
  }

  /// Not persisted — same purpose as `hotKeyRegistrationFailed` but for the
  /// jump-to-next-idle hotkey.
  @Published var jumpHotKeyRegistrationFailed: Bool = false

  /// Extra transcript context shown in the popover's "LAST MESSAGE" preview
  /// panel, when the transcript actually has it — all default to on.
  @Published var previewShowGitBranch: Bool {
    didSet { UserDefaults.standard.set(previewShowGitBranch, forKey: Keys.previewShowGitBranch) }
  }

  @Published var previewShowModel: Bool {
    didSet { UserDefaults.standard.set(previewShowModel, forKey: Keys.previewShowModel) }
  }

  @Published var previewShowLastPrompt: Bool {
    didSet {
      UserDefaults.standard.set(previewShowLastPrompt, forKey: Keys.previewShowLastPrompt)
    }
  }

  @Published var previewShowToolActivity: Bool {
    didSet {
      UserDefaults.standard.set(previewShowToolActivity, forKey: Keys.previewShowToolActivity)
    }
  }

  @Published var sortMode: SortMode {
    didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: Keys.sortMode) }
  }

  private init() {
    let defaults = UserDefaults.standard
    targetApp = defaults.string(forKey: Keys.targetApp) ?? "Ghostty"
    pollInterval = defaults.object(forKey: Keys.pollInterval) as? TimeInterval ?? 2.0
    hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? UInt32 ?? UInt32(kVK_ANSI_A)
    hotKeyModifiers =
      defaults.object(forKey: Keys.hotKeyModifiers) as? UInt32
      ?? UInt32(controlKey | optionKey | shiftKey)
    jumpHotKeyCode = defaults.object(forKey: Keys.jumpHotKeyCode) as? UInt32 ?? UInt32(kVK_ANSI_W)
    jumpHotKeyModifiers =
      defaults.object(forKey: Keys.jumpHotKeyModifiers) as? UInt32
      ?? UInt32(controlKey | optionKey | shiftKey)
    previewShowGitBranch = defaults.object(forKey: Keys.previewShowGitBranch) as? Bool ?? true
    previewShowModel = defaults.object(forKey: Keys.previewShowModel) as? Bool ?? true
    previewShowLastPrompt = defaults.object(forKey: Keys.previewShowLastPrompt) as? Bool ?? true
    previewShowToolActivity =
      defaults.object(forKey: Keys.previewShowToolActivity) as? Bool ?? true
    sortMode =
      defaults.string(forKey: Keys.sortMode).flatMap(SortMode.init(rawValue:)) ?? .statusPriority
  }
}
