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

/// Bound to whichever keyCode/modifiers pair the caller passes — used for
/// both the main popover hotkey and the jump-to-next-idle hotkey, so the
/// recording UI/logic isn't duplicated per hotkey.
struct KeyRecorderView: View {
  @Binding var keyCode: UInt32
  @Binding var modifiers: UInt32
  let onChange: () -> Void
  @StateObject private var recorder = KeyRecorderModel()

  var body: some View {
    HStack {
      Text(HotKeyFormatter.string(keyCode: keyCode, modifiers: modifiers))
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.secondary.opacity(0.1))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(
              recorder.isRecording ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25),
              lineWidth: recorder.isRecording ? 1 : 0.5
            )
        )
      Spacer()
      Button {
        recorder.startRecording { newKeyCode, newModifiers in
          keyCode = newKeyCode
          modifiers = newModifiers
          onChange()
        }
      } label: {
        if recorder.isRecording {
          Label("Press keys…", systemImage: "record.circle")
            .foregroundStyle(.red)
        } else {
          Text("Record Shortcut")
        }
      }
      .disabled(recorder.isRecording)
    }
  }
}
