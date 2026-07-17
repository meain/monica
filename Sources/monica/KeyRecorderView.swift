import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures the next key chord typed while recording, for customizing the
/// global hotkey from Settings.
@MainActor
final class KeyRecorderModel: ObservableObject {
    @Published var isRecording = false
    nonisolated(unsafe) private var monitor: Any?

    func startRecording(onCaptured: @escaping (UInt32, UInt32) -> Void) {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var carbonMods: UInt32 = 0
            if event.modifierFlags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            // Require at least one modifier so a bare letter key doesn't
            // silently become a global shortcut.
            guard carbonMods != 0 else { return event }
            self.stopRecording()
            onCaptured(UInt32(event.keyCode), carbonMods)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct KeyRecorderView: View {
    @ObservedObject var settings: AppSettings
    let onChange: () -> Void
    @StateObject private var recorder = KeyRecorderModel()

    var body: some View {
        HStack {
            Text(HotKeyFormatter.string(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
            Button(recorder.isRecording ? "Press keys…" : "Record Shortcut") {
                recorder.startRecording { keyCode, modifiers in
                    settings.hotKeyCode = keyCode
                    settings.hotKeyModifiers = modifiers
                    onChange()
                }
            }
            .disabled(recorder.isRecording)
        }
    }
}
