import AppKit
import SwiftUI

/// `NSStatusItem` + `NSPopover`, templated on mactraffic's `StatusBarController`.
/// The status item's title shows one glyph per agent; the popover (opened
/// either by clicking the item or via the global hotkey — see
/// `HotKeyManager`) holds search, the full agent list, a message preview,
/// and Settings/Quit. All SwiftUI view code lives in `MenuBarPopoverView.swift`
/// — this file is purely the AppKit/NSPopover mechanics and `AgentScanner`
/// glue.
@MainActor
final class MenuBarController {
  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let scanner: AgentScanner
  private let model = AgentPickerModel()
  private var titleTimer: Timer?

  /// Whichever app was frontmost right before `openPopover()` activated
  /// monica itself — restored on cancel/send-message so escaping the
  /// popover hands focus back to whatever the user was actually in,
  /// instead of leaving monica (an accessory app with no visible window)
  /// as the active app. Not restored on commit, since `Switcher.activate`
  /// deliberately raises the target terminal app instead.
  private var previousApp: NSRunningApplication?

  init(scanner: AgentScanner, onOpenSettings: @escaping () -> Void) {
    self.scanner = scanner
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.popover = NSPopover()
    popover.behavior = .transient
    // Explicit size, matching mactraffic's `StatusBarController`. Without
    // this, NSPopover has to guess a size from the hosted SwiftUI view
    // before its first layout pass — that ambiguous guess is what caused
    // the popover to anchor ~180pt below the status item instead of
    // right beneath it (see AGENTS.md).
    popover.contentSize = NSSize(width: PopoverLayout.width, height: 300)

    model.onCommit = { [weak self] session in
      Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
      self?.closePopover(restorePreviousApp: false)
    }
    model.onSendMessage = { [weak self] session, text in
      Switcher.sendMessage(session, text: text)
      self?.closePopover(restorePreviousApp: true)
    }
    model.onCancel = { [weak self] in self?.closePopover(restorePreviousApp: true) }

    if let button = statusItem.button {
      button.action = #selector(handleClick(_:))
      button.target = self
    }

    let content = MenuBarPopoverView(
      model: model,
      onSettings: { [weak self] in
        self?.closePopover(restorePreviousApp: false)
        onOpenSettings()
      },
      onQuit: { NSApp.terminate(nil) }
    )
    popover.contentViewController = NSHostingController(rootView: content)

    updateTitle()
    titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateTitle() }
    }
  }

  @objc private func handleClick(_ sender: AnyObject?) {
    togglePopover()
  }

  /// Called both from the status item click and from the global hotkey —
  /// there's deliberately only one picker UI now, not a separate Spotlight
  /// window.
  func togglePopover() {
    if popover.isShown {
      closePopover(restorePreviousApp: true)
    } else {
      openPopover()
    }
  }

  /// Debug helper for `MONICA_SHOT`: opens the popover and renders its
  /// backing window's full content (arrow/chrome included, not just the
  /// SwiftUI content view) to a PNG — bypasses Screen Recording permission
  /// entirely by using AppKit's own offscreen `cacheDisplay`, same technique
  /// as booker's `BOOKER_SHOT` (see booker's AGENTS.md). Gated behind the env
  /// var; has no effect on normal launches.
  func renderPopoverToFile(_ path: String, delay: Double) {
    openPopover()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let window = self.popover.contentViewController?.view.window,
        let contentView = window.contentView,
        let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
      else {
        NSApp.terminate(nil)
        return
      }
      contentView.cacheDisplay(in: contentView.bounds, to: rep)
      if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
      }
      NSApp.terminate(nil)
    }
  }

  /// Debug helper for `MONICA_SHOT_MENUBAR`: renders the status item's own
  /// button (the glyph strip) to a PNG. Same technique as
  /// `renderPopoverToFile`.
  func renderMenuBarToFile(_ path: String) {
    guard let button = statusItem.button,
      let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
    else { return }
    button.cacheDisplay(in: button.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }

  private func openPopover() {
    guard let button = statusItem.button else { return }
    previousApp = NSWorkspace.shared.frontmostApplication
    scanner.scan()
    model.activate(sessions: scanner.sessions)
    resizeForScreen()
    NSApp.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()

    // `.onAppear`'s `searchFocused = true` races the window actually
    // becoming key — that assignment can get silently dropped if it
    // lands before `makeKey()` has taken effect. Retry once the run
    // loop has caught up, after re-confirming key status.
    DispatchQueue.main.async { [weak self] in
      self?.popover.contentViewController?.view.window?.makeKey()
      self?.model.requestFocus()
    }
  }

  private func closePopover(restorePreviousApp: Bool) {
    model.deactivate()
    popover.performClose(nil)
    if restorePreviousApp {
      previousApp?.activate()
    }
  }

  /// Sizes the list to how many agents are actually showing, not always to
  /// the maximum — only clamped by 60% of the active screen's height for
  /// when there are a lot of them. `fixedChrome` is a rough estimate of
  /// everything in the popover besides the scrollable list (search field,
  /// preview panel, footer, dividers) — `NSPopover.contentSize` is itself
  /// just a hint (see AGENTS.md), so this doesn't need to be exact.
  private func resizeForScreen() {
    let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    let fixedChrome: CGFloat = 220
    let maxListHeight = max(agentRowHeight, screenHeight * 0.6 - fixedChrome)
    let rowCount = model.filteredSessions.count
    let desiredListHeight =
      rowCount == 0 ? emptyListHeight : CGFloat(rowCount) * agentRowHeight + 8
    let listHeight = min(desiredListHeight, maxListHeight)
    model.listHeight = listHeight
    popover.contentSize = NSSize(width: PopoverLayout.width, height: fixedChrome + listHeight)
  }

  /// One glyph per agent, colored by status — the same "at a glance" display
  /// the old always-on HUD strip gave, now living directly in the menu bar
  /// title instead of a separate floating window.
  private func updateTitle() {
    guard let button = statusItem.button else { return }
    let sessions = scanner.sessions
    // Menlo, not the SF monospaced system font: SF mono has no ◌ (U+25CC), so
    // the stale glyph silently fell back to Menlo while ▶ ● ○ stayed SF —
    // mismatched sizes/baselines, visibly misaligned in the menu bar. Menlo
    // covers all four glyphs, so they align with each other by design.
    let font =
      NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let title = NSMutableAttributedString()

    if sessions.isEmpty {
      title.append(
        NSAttributedString(
          string: "○", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    } else {
      for (index, session) in sessions.enumerated() {
        if index > 0 {
          title.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        let color: NSColor =
          session.isStale || session.isQuiet
          ? .secondaryLabelColor
          : (session.status == .working
            ? .systemGreen : session.status == .waiting ? .systemYellow : .secondaryLabelColor)
        title.append(
          NSAttributedString(
            string: session.displayGlyph, attributes: [.font: font, .foregroundColor: color]))
      }
    }

    button.attributedTitle = title
    if popover.isShown {
      model.refreshData(sessions)
    }
  }
}
