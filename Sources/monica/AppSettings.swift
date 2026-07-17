import Foundation
import Carbon.HIToolbox

/// UserDefaults-backed settings, shared across the menu bar, HUD, and Spotlight
/// surfaces. Kept intentionally small for v1 — see DESIGN.md's "future work"
/// for what's deliberately not configurable yet (HUD position, per-agent
/// filtering, etc).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let targetApp = "monica.targetApp"
        static let pollInterval = "monica.pollInterval"
        static let hudEnabled = "monica.hudEnabled"
        static let hotKeyCode = "monica.hotKeyCode"
        static let hotKeyModifiers = "monica.hotKeyModifiers"
    }

    /// The app name passed to `open -a <targetApp>` when switching. Ghostty by
    /// default, but configurable since the switch target is meant to be swappable.
    @Published var targetApp: String {
        didSet { UserDefaults.standard.set(targetApp, forKey: Keys.targetApp) }
    }

    @Published var pollInterval: TimeInterval {
        didSet { UserDefaults.standard.set(pollInterval, forKey: Keys.pollInterval) }
    }

    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: Keys.hudEnabled) }
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

    private init() {
        let defaults = UserDefaults.standard
        targetApp = defaults.string(forKey: Keys.targetApp) ?? "Ghostty"
        pollInterval = defaults.object(forKey: Keys.pollInterval) as? TimeInterval ?? 2.0
        hudEnabled = defaults.object(forKey: Keys.hudEnabled) as? Bool ?? true
        hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? UInt32 ?? UInt32(kVK_ANSI_A)
        hotKeyModifiers =
            defaults.object(forKey: Keys.hotKeyModifiers) as? UInt32
            ?? UInt32(controlKey | optionKey | shiftKey)
    }
}
