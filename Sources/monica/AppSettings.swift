import Carbon.HIToolbox
import Foundation

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
  /// `.waiting` agent (cycling on repeated presses) without opening the
  /// popover at all — default ⌃⌥⇧W, same reasoning as `hotKeyCode`'s doc
  /// comment for avoiding the Hammerspoon hyper-key prefix.
  @Published var jumpHotKeyCode: UInt32 {
    didSet { UserDefaults.standard.set(jumpHotKeyCode, forKey: Keys.jumpHotKeyCode) }
  }

  @Published var jumpHotKeyModifiers: UInt32 {
    didSet { UserDefaults.standard.set(jumpHotKeyModifiers, forKey: Keys.jumpHotKeyModifiers) }
  }

  /// Not persisted — same purpose as `hotKeyRegistrationFailed` but for the
  /// jump-to-next-waiting hotkey.
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
  }
}
