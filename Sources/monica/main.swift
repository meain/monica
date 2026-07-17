import AppKit

// Not marked @MainActor: the top-level `AppDelegate()` call below runs in
// main.swift's implicit nonisolated top-level context. Everything that
// touches @MainActor-isolated types (AgentScanner, HotKeyManager, etc.) is
// deferred into applicationDidFinishLaunching, which the AppKit overlay
// already runs on the main actor — same structure as beacon's AppDelegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scanner: AgentScanner?
    private var hotKeyManager: HotKeyManager?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let scanner = AgentScanner()
        self.scanner = scanner
        let hotKeyManager = HotKeyManager()
        self.hotKeyManager = hotKeyManager

        menuBar = MenuBarController(scanner: scanner) { [weak self] in
            self?.showSettings()
        }

        scanner.start(interval: AppSettings.shared.pollInterval)
        registerHotKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// There is deliberately only one picker UI: the global hotkey opens the
    /// same menu bar popover a click would, rather than a separate Spotlight
    /// window.
    @MainActor
    private func registerHotKey() {
        guard let hotKeyManager else { return }
        hotKeyManager.register(
            keyCode: AppSettings.shared.hotKeyCode,
            modifiers: AppSettings.shared.hotKeyModifiers
        ) { [weak self] in
            self?.menuBar?.togglePopover()
        }
    }

    @MainActor
    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: AppSettings.shared) { [weak self] in
                self?.registerHotKey()
            }
        }
        settingsWindow?.show()
    }

    /// A minimal menu so ⌘Q works even with no dock icon / visible window.
    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit monica", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
