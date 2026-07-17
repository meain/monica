import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onHotKeyChanged: () -> Void

    var body: some View {
        Form {
            Section("Quickstart") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click the menu bar icon, or press the hotkey below, to open the picker.")
                    Text("Type to filter, ↑↓ to move, ↩ to switch to an agent's pane.")
                    Text("⌘↩ instead sends a message to the pane without switching to it.")
                    Text("▶ working   ● waiting   ○ idle   ◌ idle for over 3 hours")
                        .font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("Switch target") {
                HStack {
                    TextField("App name", text: $settings.targetApp)
                    Button("Choose…") { chooseApp() }
                }
                Text("Passed to `open -a <app>` when switching to an agent's pane.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Global hotkey") {
                KeyRecorderView(settings: settings, onChange: onHotKeyChanged)
                Text("Opens the same picker as clicking the menu bar icon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Scanning") {
                Stepper(value: $settings.pollInterval, in: 1...10, step: 1) {
                    Text("Poll every \(Int(settings.pollInterval))s")
                }
            }
        }
        .padding(20)
        .frame(width: 380)
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
