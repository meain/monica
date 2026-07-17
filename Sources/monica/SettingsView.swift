import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A keyboard-key-styled chip ("⌘↩", "esc") used by the Shortcuts section.
private struct KeyCap: View {
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

private struct ShortcutRow: View {
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
    }
  }
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  let onHotKeyChanged: () -> Void

  private var version: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  private var hotKeyLabel: String {
    HotKeyFormatter.string(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
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
        ShortcutRow(title: "Open the picker", keys: [hotKeyLabel])
        ShortcutRow(title: "Filter and move", keys: ["type", "↑", "↓"])
        ShortcutRow(title: "Switch to the selected agent", keys: ["↩"])
        ShortcutRow(title: "Send a message without switching", keys: ["⌘↩"])
      } header: {
        Text("Shortcuts")
      } footer: {
        Text("Clicking the menu bar icon opens the same picker as the hotkey.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        LegendRow(glyph: "▶", color: .green, name: "Working", detail: "Running a task right now")
        LegendRow(glyph: "●", color: .yellow, name: "Waiting", detail: "Needs your input")
        LegendRow(glyph: "○", color: .secondary, name: "Idle", detail: "Nothing in progress")
        LegendRow(
          glyph: "◌", color: .secondary, name: "Stale",
          detail: "No status updates for over 3 hours")
      } header: {
        Text("Status legend")
      } footer: {
        Text("The same glyphs appear in the menu bar, one per agent.")
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
        KeyRecorderView(settings: settings, onChange: onHotKeyChanged)
      } header: {
        Text("Global hotkey")
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
    .frame(width: 480, height: 760)
  }

  private func openDocs() {
    guard let url = URL(string: "https://github.com/meain/monica/blob/main/docs.md") else { return }
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
  convenience init(settings: AppSettings, onHotKeyChanged: @escaping () -> Void) {
    let view = SettingsView(settings: settings, onHotKeyChanged: onHotKeyChanged)
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
