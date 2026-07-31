import Carbon.HIToolbox
import Foundation

/// Global hotkey registration via Carbon's `RegisterEventHotKey`. This is the
/// same mechanism launcher apps (Alfred, Spotlight-alikes) have long used —
/// unlike an `NSEvent` global monitor it doesn't require Accessibility/Input
/// Monitoring permission.
@MainActor
final class HotKeyManager {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var action: (() -> Void)?

  // Arbitrary 4-char signature identifying monica's hotkeys to Carbon.
  private let signature: OSType = 0x6d6f_6e69

  /// Unique per instance — monica registers two independent hotkeys (the
  /// main popover one and jump-to-next-idle), each via its own
  /// `HotKeyManager`. Every instance previously hardcoded `id: 1`, and the
  /// event handler below never checked the fired event's id against its
  /// own before acting — so whichever instance's `InstallEventHandler`
  /// call happened to be *last* in Carbon's handler chain silently
  /// swallowed every hotkey press for both chords, since each handler
  /// unconditionally ran its own action and returned `noErr` without
  /// forwarding the event. A unique id, checked before acting, fixes that.
  private static var nextId: UInt32 = 1
  private let id: UInt32

  init() {
    id = Self.nextId
    Self.nextId += 1
  }

  /// Returns whether `RegisterEventHotKey` actually succeeded. Carbon fails
  /// *silently* when the chord is already claimed by another app (e.g. a
  /// Hammerspoon hyper-key binding, see AGENTS.md) — no error dialog, no
  /// exception, the hotkey just never fires. Previously this status was
  /// discarded entirely, so that failure mode was undiagnosable from inside
  /// the app. Callers use the return value to surface a warning instead.
  @discardableResult
  func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
    unregister()
    self.action = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )

    InstallEventHandler(
      GetApplicationEventTarget(),
      { callRef, eventRef, userData -> OSStatus in
        guard let eventRef, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        // Every `HotKeyManager` installs its own handler on the same
        // shared application event target, so this fires for *any*
        // registered hotkey, not just this instance's — only act (and
        // consume the event) when the id actually matches; otherwise
        // forward it down the chain so the manager it does belong to
        // gets a chance to handle it.
        guard hotKeyID.signature == manager.signature, hotKeyID.id == manager.id else {
          return CallNextEventHandler(callRef, eventRef)
        }
        manager.action?()
        return noErr
      },
      1, &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )

    let hotKeyID = EventHotKeyID(signature: signature, id: id)
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    return status == noErr
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }
}
