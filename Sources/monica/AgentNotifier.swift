import AppKit
import Combine
import UserNotifications

/// Desktop notifications when an agent starts awaiting you: finished its
/// turn (working → idle) or got blocked on a prompt (→ waiting). Clicking
/// one (or its Switch action) switches to that agent's pane, same as Return
/// in the popover; its Reply action sends a message into the pane instead.
///
/// Driven purely by diffing successive `AgentScanner.sessions` values — no
/// hooks of its own. Keyed by pane + pid so a pane that gets a new agent
/// process isn't mistaken for a transition. The first scan after launch only
/// primes the state (no burst of notifications for everything already idle),
/// and a working → idle flip has to hold for `idleSettle` before it fires,
/// so a brief idle blip between turns doesn't notify. Suppressed while you're
/// already looking at that pane (target app frontmost *and* the tmux client
/// showing it) or the popover is open.
///
/// `UNUserNotificationCenter` needs a real bundle (it raises for an
/// unbundled `swift run` binary), so without one this falls back to
/// `osascript display notification` — same banner, but no click-to-switch.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
  private let scanner: AgentScanner
  private let isPopoverShown: () -> Bool
  private var subscription: AnyCancellable?

  private var lastStatus: [String: AgentStatus] = [:]
  private var primed = false
  private var pendingIdle: [String: Task<Void, Never>] = [:]
  /// When the current turn started, for the duration in the title. Kept
  /// across a waiting → working hop (approving a prompt continues the same
  /// turn); absent for turns already running at launch.
  private var workingSince: [String: Date] = [:]

  private static let idleSettle: Duration = .seconds(3)
  private static let hasBundle = Bundle.main.bundleIdentifier != nil

  private enum Reason { case finished, blocked }

  private static let agentCategory = "monica.agent"
  private static let switchAction = "monica.switch"
  private static let replyAction = "monica.reply"

  /// Switch does what a plain click does; Reply sends the typed text into
  /// the pane via `Switcher.sendMessage`, same as ⌘Return in the popover,
  /// without bringing the terminal forward.
  private static func makeAgentCategory() -> UNNotificationCategory {
    let switchTo = UNNotificationAction(identifier: switchAction, title: "Switch")
    let reply = UNTextInputNotificationAction(
      identifier: replyAction, title: "Reply…",
      textInputButtonTitle: "Send", textInputPlaceholder: "Message to agent")
    return UNNotificationCategory(
      identifier: agentCategory, actions: [switchTo, reply], intentIdentifiers: [])
  }

  init(scanner: AgentScanner, isPopoverShown: @escaping () -> Bool) {
    self.scanner = scanner
    self.isPopoverShown = isPopoverShown
    super.init()
    // Must be set before launch finishes, or a click that launched/
    // activated the app is delivered to nobody.
    if Self.hasBundle {
      let center = UNUserNotificationCenter.current()
      center.delegate = self
      center.setNotificationCategories([Self.makeAgentCategory()])
    }
    subscription = scanner.$sessions.sink { [weak self] sessions in
      self?.observe(sessions)
    }
  }

  /// Asks for permission — called when the Settings toggle is switched on,
  /// not at launch, so the one-shot system prompt appears in response to
  /// something the user just did.
  static func requestAuthorization(then completion: (@MainActor (Bool) -> Void)? = nil) {
    guard hasBundle else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          AppSettings.shared.notificationsDenied = !granted
          completion?(granted)
        }
      }
    }
  }

  /// Settings' "Send test" button — goes through the same permission check
  /// and delivery path as a real notification, so it confirms the whole
  /// chain (permission, banner style, Focus mode) rather than just the UI.
  static func sendTest() {
    let send = {
      deliver(
        title: "Monica · 4m 12s",
        body: "Test notification — this is how an agent finishing will look.",
        identifier: "monica.test", paneId: nil)
    }
    guard hasBundle else {
      send()
      return
    }
    requestAuthorization { granted in if granted { send() } }
  }

  private static func key(_ session: AgentSession) -> String {
    "\(session.paneId):\(session.agentPid)"
  }

  private func observe(_ sessions: [AgentSession]) {
    var current: [String: AgentStatus] = [:]
    for session in sessions {
      let key = Self.key(session)
      current[key] = session.status
      guard primed, let previous = lastStatus[key], previous != session.status else { continue }

      let elapsed = workingSince[key].map { Date().timeIntervalSince($0) }
      switch session.status {
      case .waiting:
        cancelPending(key)
        post(session, reason: .blocked, elapsed: elapsed)
      case .idle where previous == .working:
        workingSince[key] = nil
        schedule(session, key: key, elapsed: elapsed)
      case .working:
        // Back at work: whatever we said about this pane is moot now.
        cancelPending(key)
        if previous != .waiting || workingSince[key] == nil { workingSince[key] = Date() }
        if Self.hasBundle {
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
        }
      case .idle:
        workingSince[key] = nil
      }
    }
    for key in lastStatus.keys where current[key] == nil {
      cancelPending(key)
      workingSince[key] = nil
    }
    lastStatus = current
    primed = true
  }

  private func schedule(_ session: AgentSession, key: String, elapsed: TimeInterval?) {
    cancelPending(key)
    pendingIdle[key] = Task { [weak self] in
      try? await Task.sleep(for: Self.idleSettle)
      guard !Task.isCancelled, let self else { return }
      self.pendingIdle[key] = nil
      guard let latest = self.scanner.sessions.first(where: { Self.key($0) == key }),
        latest.status == .idle
      else { return }
      self.post(latest, reason: .finished, elapsed: elapsed)
    }
  }

  private func cancelPending(_ key: String) {
    pendingIdle.removeValue(forKey: key)?.cancel()
  }

  private func post(_ session: AgentSession, reason: Reason, elapsed: TimeInterval?) {
    guard AppSettings.shared.notificationsEnabled, !isPopoverShown() else { return }
    let targetApp = AppSettings.shared.targetApp
    // Focus check and transcript read both touch tmux/disk — off main.
    Task.detached {
      if Self.isViewing(session, targetApp: targetApp) { return }
      // Only a blocked agent gets the menu bar's ◆ in front, so it stands
      // out from the plain finished ones; turn duration trails the name.
      let prefix: String
      let body: String
      switch reason {
      case .blocked:
        prefix = "\(AgentStatus.waiting.glyph) "
        body = session.waitingFor ?? "Blocked"
      case .finished:
        prefix = ""
        body = Self.snippet(TranscriptPreview.details(for: session).text) ?? "Awaiting you"
      }
      let duration = elapsed.map { " · \(Self.formatDuration($0))" } ?? ""
      let title = "\(prefix)\(session.displayName)\(duration)"
      // Same identifier per pane + pid, so a newer notification replaces an
      // older one for the same agent instead of stacking.
      await MainActor.run {
        Self.deliver(
          title: title, body: body, identifier: Self.key(session), paneId: session.paneId)
      }
    }
  }

  /// `paneId` (when set) is what a click switches to.
  private static func deliver(title: String, body: String, identifier: String, paneId: String?) {
    let sound = AppSettings.shared.notificationSound
    playSound(sound)
    guard hasBundle else {
      runFireAndForget(
        "/usr/bin/osascript",
        [
          "-e", "on run argv", "-e",
          "display notification (item 2 of argv) with title (item 1 of argv)",
          "-e", "end run", "--", title, body,
        ])
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = sound == NotificationSound.systemDefault ? .default : nil
    if let paneId {
      content.threadIdentifier = paneId
      content.userInfo = ["paneId": paneId]
      content.categoryIdentifier = agentCategory
    }
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  /// True when the configured terminal is frontmost and the (single, per
  /// DESIGN.md) attached tmux client is showing this exact pane.
  private nonisolated static func isViewing(_ session: AgentSession, targetApp: String) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication else { return false }
    let appName = front.localizedName ?? ""
    let bundleName = front.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
    guard
      appName.caseInsensitiveCompare(targetApp) == .orderedSame
        || bundleName.caseInsensitiveCompare(targetApp) == .orderedSame
    else { return false }
    guard let client = Switcher.firstAttachedClient() else { return false }
    let pane = TmuxCLI.run(["display-message", "-p", "-c", client, "#{pane_id}"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return pane == session.paneId
  }

  /// A custom sound is played by monica itself rather than attached to the
  /// notification: `UNNotificationSound(named:)` only looks in the app's
  /// bundle and `~/Library/Sounds`, not `/System/Library/Sounds`. The
  /// catch is that it plays even when Focus hides the banner.
  private static var currentSound: NSSound?

  static func playSound(_ name: String) {
    guard name != NotificationSound.systemDefault, name != NotificationSound.none else { return }
    currentSound?.stop()
    currentSound = NSSound(named: NSSound.Name(name))
    currentSound?.play()
  }

  /// "38s", "4m 12s", "1h 5m".
  private nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = total % 3600 / 60
    let s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
  }

  /// First ~140 chars of the last message, flattened to one line with the
  /// commonest markdown markers dropped — banners show plain text only.
  private nonisolated static func snippet(_ text: String?) -> String? {
    guard let text, !text.hasPrefix("(") else { return nil }
    var flat = text.replacingOccurrences(of: "\n", with: " ")
    for marker in ["**", "`", "#"] { flat = flat.replacingOccurrences(of: marker, with: "") }
    flat = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    guard !flat.isEmpty else { return nil }
    return flat.count > 140 ? String(flat.prefix(139)) + "…" : flat
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let paneId = response.notification.request.content.userInfo["paneId"] as? String
    let action = response.actionIdentifier
    let replyText = (response as? UNTextInputNotificationResponse)?.userText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let paneId, let session = self.scanner.sessions.first(where: { $0.paneId == paneId })
        else { return }
        switch action {
        case Self.replyAction:
          if let replyText, !replyText.isEmpty { Switcher.sendMessage(session, text: replyText) }
        case Self.switchAction, UNNotificationDefaultActionIdentifier:
          Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
        default:
          break  // dismissed
        }
      }
      completionHandler()
    }
  }

  /// monica is an accessory app, so it's rarely "foreground" — but when it
  /// is (Settings open), still show the banner rather than swallowing it.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
