import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A keyboard-key-styled chip ("⌘↩", "esc") used by the Shortcuts section.
/// Not `private` — also reused by `MenuBarPopoverView`'s in-popover
/// shortcuts panel, so the two surfaces render identically.
struct KeyCap: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.secondary.opacity(0.1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
      )
  }
}

/// Not `private` — see `KeyCap`'s doc comment.
struct ShortcutRow: View {
  let title: String
  let keys: [String]

  var body: some View {
    HStack {
      Text(title)
        .font(.system(size: 12))
      Spacer()
      HStack(spacing: 4) {
        ForEach(keys, id: \.self) { KeyCap(label: $0) }
      }
    }
  }
}

private struct LegendRow: View {
  let glyph: String
  let color: Color
  let name: String
  let detail: String
  /// Live count of currently-running agents in this category — turns the
  /// legend from a static reference into a mini live dashboard. Hidden
  /// (rather than showing "0") when there's nothing to report.
  var count: Int = 0

  var body: some View {
    HStack(spacing: 10) {
      Text(glyph)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(color)
        .frame(width: 16)
      Text(name)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 56, alignment: .leading)
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
    }
  }
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var scanner: AgentScanner
  let onHotKeyChanged: () -> Void
  let onJumpHotKeyChanged: () -> Void

  private var version: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  private var hotKeyLabel: String {
    HotKeyFormatter.string(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
  }

  private var jumpHotKeyLabel: String {
    HotKeyFormatter.string(
      keyCode: settings.jumpHotKeyCode, modifiers: settings.jumpHotKeyModifiers)
  }

  // Same categorization `MenuBarPopoverView`'s footer summary uses: working/
  // waiting/idle all require !isStale && !isQuiet, since those two states
  // override the glyph regardless of the underlying status.
  private var workingCount: Int {
    scanner.sessions.filter { $0.status == .working && !$0.isStale && !$0.isQuiet }.count
  }
  private var waitingCount: Int {
    scanner.sessions.filter { $0.status == .waiting && !$0.isStale && !$0.isQuiet }.count
  }
  private var idleCount: Int {
    scanner.sessions.filter { $0.status == .idle && !$0.isStale && !$0.isQuiet }.count
  }
  private var quietCount: Int {
    scanner.sessions.filter { $0.isQuiet && !$0.isStale }.count
  }
  private var staleCount: Int {
    scanner.sessions.filter { $0.isStale }.count
  }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          ZStack {
            RoundedRectangle(cornerRadius: 10)
              .fill(
                LinearGradient(
                  colors: [.blue, .purple],
                  startPoint: .topLeading, endPoint: .bottomTrailing
                )
              )
              .frame(width: 40, height: 40)
            Image(systemName: "rectangle.stack.fill")
              .font(.system(size: 17, weight: .medium))
              .foregroundStyle(.white)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text("Monica")
              .font(.system(size: 15, weight: .semibold))
            Text("Watch and switch between AI agents in tmux")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let version {
            Text("v\(version)")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
          Button("Setup Guide…") { openDocs() }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.vertical, 2)
        // `.formStyle(.grouped)` is backed by a List, which has the
        // same legacy-NSScroller-doesn't-respect-.scrollIndicators
        // issue as a plain ScrollView (see ScrollbarSuppressor's doc
        // comment) — this section's content is as good a place as
        // any inside the Form's scrollable area to attach it.
        .background(ScrollbarSuppressor())
      }

      Section {
        if settings.hotKeyRegistrationFailed {
          Label {
            Text(
              "\"\(hotKeyLabel)\" didn't register — it's likely already claimed by another "
                + "app (e.g. Hammerspoon). Pick a different shortcut below."
            )
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
        ShortcutRow(title: "Open the picker", keys: [hotKeyLabel])
        ShortcutRow(title: "Filter and move", keys: ["type", "↑", "↓"])
        ShortcutRow(title: "Switch to the selected agent", keys: ["↩"])
        ShortcutRow(title: "Send a message without switching", keys: ["⌘↩"])
        ShortcutRow(title: "Copy last message", keys: ["⌘⇧C"])
      } header: {
        Text("Shortcuts")
      } footer: {
        Text("Clicking the menu bar icon opens the same picker as the hotkey.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        LegendRow(
          glyph: "▶", color: .green, name: "Working", detail: "Running a task right now",
          count: workingCount)
        LegendRow(
          glyph: "●", color: .yellow, name: "Waiting", detail: "Needs your input",
          count: waitingCount)
        LegendRow(
          glyph: "○", color: .secondary, name: "Idle", detail: "Nothing in progress",
          count: idleCount)
        LegendRow(
          glyph: "●", color: .secondary, name: "Quiet",
          detail: "No status updates for 15+ minutes", count: quietCount)
        LegendRow(
          glyph: "◌", color: .secondary, name: "Stale",
          detail: "No status updates for over 3 hours", count: staleCount)
      } header: {
        Text("Status legend")
      } footer: {
        Text("The same glyphs appear in the menu bar, one per agent.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        // `.recency` is listed first (it's the previous default), then the
        // rest starting with `.statusPriority` — the actual current default
        // (`AppSettings.init`). A dropdown rather than segmented control
        // since eight modes don't fit a segmented row at this width.
        Picker("Sort agents by", selection: $settings.sortMode) {
          ForEach(SortMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.menu)
      } footer: {
        Text(settings.sortMode.detail)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        Toggle("Git branch", isOn: $settings.previewShowGitBranch)
        Toggle("Model", isOn: $settings.previewShowModel)
        Toggle("Last prompt", isOn: $settings.previewShowLastPrompt)
        Toggle("Tool activity", isOn: $settings.previewShowToolActivity)
      } header: {
        Text("Preview details")
      } footer: {
        Text(
          "Extra context shown in the LAST MESSAGE panel when the transcript has it — "
            + "git branch, model, your last prompt, and the last tool call."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        LabeledContent("Application") {
          HStack {
            TextField("App name", text: $settings.targetApp)
              .textFieldStyle(.roundedBorder)
            Button("Choose…") { chooseApp() }
          }
        }
      } header: {
        Text("Switch target")
      } footer: {
        Text("Passed to `open -a <app>` when switching to an agent's pane.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        KeyRecorderView(
          keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers,
          onChange: onHotKeyChanged)
      } header: {
        Text("Global hotkey")
      }

      Section {
        if settings.jumpHotKeyRegistrationFailed {
          Label {
            Text(
              "\"\(jumpHotKeyLabel)\" didn't register — it's likely already claimed by "
                + "another app. Pick a different shortcut below."
            )
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
        KeyRecorderView(
          keyCode: $settings.jumpHotKeyCode, modifiers: $settings.jumpHotKeyModifiers,
          onChange: onJumpHotKeyChanged)
      } header: {
        Text("Jump to next waiting agent")
      } footer: {
        Text(
          "Switches straight to the next agent that's waiting on you, cycling on repeated "
            + "presses — no popover needed."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        Stepper(value: $settings.pollInterval, in: 1...10, step: 1) {
          LabeledContent("Refresh agents every") {
            Text("\(Int(settings.pollInterval))s")
              .monospacedDigit()
          }
        }
      } header: {
        Text("Scanning")
      }
    }
    .formStyle(.grouped)
    // `NSWindow(contentViewController:)` doesn't reliably read a
    // `.formStyle(.grouped)` Form's ideal height the way it did for the
    // old plain-style Form — without an explicit height the window
    // collapsed to ~32pt (just the titlebar, no content at all,
    // confirmed via a real screenshot). The height must also comfortably
    // fit *all* sections, or the Form's internal List scrolls (with a
    // visible scrollbar despite ScrollbarSuppressor above, since hiding
    // the scroller doesn't stop the content from overflowing).
    .frame(width: 480, height: 900)
  }

  private func openDocs() {
    guard let url = URL(string: "https://github.com/meain/monica/blob/master/docs.md") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func chooseApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.targetApp = url.deletingPathExtension().lastPathComponent
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  convenience init(
    settings: AppSettings, scanner: AgentScanner,
    onHotKeyChanged: @escaping () -> Void,
    onJumpHotKeyChanged: @escaping () -> Void
  ) {
    let view = SettingsView(
      settings: settings, scanner: scanner, onHotKeyChanged: onHotKeyChanged,
      onJumpHotKeyChanged: onJumpHotKeyChanged)
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Monica Settings"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    self.init(window: window)
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}
