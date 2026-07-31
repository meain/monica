import AppKit

// Not marked @MainActor: the top-level `AppDelegate()` call below runs in
// main.swift's implicit nonisolated top-level context. Everything that
// touches @MainActor-isolated types (AgentScanner, HotKeyManager, etc.) is
// deferred into applicationDidFinishLaunching, which the AppKit overlay
// already runs on the main actor — same structure as beacon's AppDelegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var scanner: AgentScanner?
  private var hotKeyManager: HotKeyManager?
  private var jumpHotKeyManager: HotKeyManager?
  private var menuBar: MenuBarController?
  private var settingsWindow: SettingsWindowController?

  /// Which pane the jump-to-next-idle hotkey last switched to, so
  /// repeated presses cycle forward through `.idle` agents instead of
  /// always landing on the first one.
  private var lastJumpedPaneId: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupMenu()

    let scanner = AgentScanner()
    self.scanner = scanner
    let hotKeyManager = HotKeyManager()
    self.hotKeyManager = hotKeyManager
    let jumpHotKeyManager = HotKeyManager()
    self.jumpHotKeyManager = jumpHotKeyManager

    menuBar = MenuBarController(scanner: scanner) { [weak self] in
      self?.showSettings()
    }

    scanner.start(interval: AppSettings.shared.pollInterval)
    registerHotKey()
    registerJumpHotKey()

    // Debug helper: MONICA_SHOT=/path renders the popover to a PNG and exits;
    // MONICA_SHOT_MENUBAR=/path (independently) renders just the menu bar
    // glyph strip; MONICA_SHOT_HELP=1 (with MONICA_SHOT) forces the in-popover
    // shortcuts panel open before the shot fires. Needs no Screen Recording
    // permission — see MenuBarController.renderPopoverToFile.
    let env = ProcessInfo.processInfo.environment
    if let menuBarShot = env["MONICA_SHOT_MENUBAR"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.menuBar?.renderMenuBarToFile(menuBarShot)
        if env["MONICA_SHOT"] == nil { NSApp.terminate(nil) }
      }
    }
    if let shotPath = env["MONICA_SHOT"] {
      let delay = Double(env["MONICA_SHOT_DELAY"] ?? "1.5") ?? 1.5
      let forceHelp = env["MONICA_SHOT_HELP"] == "1"
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.menuBar?.renderPopoverToFile(shotPath, delay: delay, forceHelp: forceHelp)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// There is deliberately only one picker UI: the global hotkey opens the
  /// same menu bar popover a click would, rather than a separate Spotlight
  /// window.
  @MainActor
  private func registerHotKey() {
    guard let hotKeyManager else { return }
    let succeeded = hotKeyManager.register(
      keyCode: AppSettings.shared.hotKeyCode,
      modifiers: AppSettings.shared.hotKeyModifiers
    ) { [weak self] in
      self?.menuBar?.togglePopover()
    }
    AppSettings.shared.hotKeyRegistrationFailed = !succeeded
  }

  /// Bypasses the popover entirely: cycles through fresh `.idle` agents
  /// (finished their turn and awaiting you; stale/quiet ones excluded) in the
  /// scanner's most-recently-updated-first order on each press, wrapping back
  /// to the first once the end is reached or the previously-jumped-to pane is
  /// no longer idle.
  @MainActor
  private func registerJumpHotKey() {
    guard let jumpHotKeyManager else { return }
    let succeeded = jumpHotKeyManager.register(
      keyCode: AppSettings.shared.jumpHotKeyCode,
      modifiers: AppSettings.shared.jumpHotKeyModifiers
    ) { [weak self] in
      self?.jumpToNextIdle()
    }
    AppSettings.shared.jumpHotKeyRegistrationFailed = !succeeded
  }

  @MainActor
  private func jumpToNextIdle() {
    guard let scanner else { return }
    let idle = scanner.sessions.filter { $0.status == .idle && !$0.isStale && !$0.isQuiet }
    guard !idle.isEmpty else { return }
    let nextIndex: Int
    if let lastJumpedPaneId, let idx = idle.firstIndex(where: { $0.paneId == lastJumpedPaneId })
    {
      nextIndex = (idx + 1) % idle.count
    } else {
      nextIndex = 0
    }
    let target = idle[nextIndex]
    lastJumpedPaneId = target.paneId
    Switcher.activate(target, targetApp: AppSettings.shared.targetApp)
  }

  @MainActor
  private func showSettings() {
    guard let scanner else { return }
    if settingsWindow == nil {
      settingsWindow = SettingsWindowController(settings: AppSettings.shared, scanner: scanner) {
        [weak self] in
        self?.registerHotKey()
      } onJumpHotKeyChanged: { [weak self] in
        self?.registerJumpHotKey()
      }
    }
    settingsWindow?.show()
  }

  /// A minimal menu so ⌘Q works even with no dock icon / visible window.
  /// Also installs an Edit menu with the standard Cut/Copy/Paste/Select All
  /// items — a bare `NSApplication` has no menu bar, so without one the
  /// standard editing key equivalents (⌘V/⌘C/⌘X/⌘A) never reach text
  /// fields (paste silently fails), same gotcha as booker's
  /// `installEditMenu()`. The items don't need visible use; their mere
  /// presence with the right selectors/key equivalents is what makes the
  /// key equivalents route to the responder chain.
  private func setupMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit Monica", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    NSApp.mainMenu = mainMenu
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
