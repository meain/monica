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
    private var hud: HUDPanel?
    private var spotlight: SpotlightController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let scanner = AgentScanner()
        self.scanner = scanner
        let hotKeyManager = HotKeyManager()
        self.hotKeyManager = hotKeyManager

        menuBar = MenuBarController(scanner: scanner)
        hud = HUDPanel(scanner: scanner)
        spotlight = SpotlightController(scanner: scanner)

        scanner.start(interval: AppSettings.shared.pollInterval)
        hud?.setVisible(AppSettings.shared.hudEnabled)

        hotKeyManager.register(
            keyCode: AppSettings.shared.hotKeyCode,
            modifiers: AppSettings.shared.hotKeyModifiers
        ) { [weak self] in
            self?.spotlight?.toggle()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
