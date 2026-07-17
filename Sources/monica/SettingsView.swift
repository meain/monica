import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onHotKeyChanged: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click the menu bar icon, or press the hotkey below, to open the picker.")
                    Text("Type to filter, ↑↓ to move, ↩ to switch to an agent's pane.")
                    Text("⌘↩ instead sends a message to the pane without switching to it.")
                    Text("▶ working   ● waiting   ○ idle   ◌ idle for over 3 hours")
                        .font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // `.formStyle(.grouped)` is backed by a List, which has the
                // same legacy-NSScroller-doesn't-respect-.scrollIndicators
                // issue as a plain ScrollView (see ScrollbarSuppressor's doc
                // comment) — this section's content is as good a place as
                // any inside the Form's scrollable area to attach it.
                .background(ScrollbarSuppressor())
            } header: {
                Text("Quickstart")
            }

            Section {
                HStack {
                    TextField("App name", text: $settings.targetApp)
                    Button("Choose…") { chooseApp() }
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
            } footer: {
                Text("Opens the same picker as clicking the menu bar icon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Stepper(value: $settings.pollInterval, in: 1...10, step: 1) {
                    Text("Poll every \(Int(settings.pollInterval))s")
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
        // confirmed via a real screenshot). 480 wasn't tall enough for all
        // four sections either, forcing the Form's internal List to scroll
        // (with a visible scrollbar despite ScrollbarSuppressor above,
        // since hiding the scroller doesn't stop the content from
        // overflowing) — 640 comfortably fits all four sections with room
        // to spare, so there's nothing to scroll.
        .frame(width: 460, height: 640)
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
