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
      self?.closePopover()
    }
    model.onSendMessage = { [weak self] session, text in
      Switcher.sendMessage(session, text: text)
      self?.closePopover()
    }
    model.onCancel = { [weak self] in self?.closePopover() }

    if let button = statusItem.button {
      button.action = #selector(handleClick(_:))
      button.target = self
    }

    let content = MenuBarPopoverView(
      model: model,
      onSettings: { [weak self] in
        self?.closePopover()
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
      closePopover()
    } else {
      openPopover()
    }
  }

  private func openPopover() {
    guard let button = statusItem.button else { return }
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

  private func closePopover() {
    model.deactivate()
    popover.performClose(nil)
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
          session.isStale
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
      model.sessions = sessions
    }
  }
}
