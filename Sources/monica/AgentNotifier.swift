import AppKit
import Combine
import UserNotifications

/// Desktop notifications when an agent starts awaiting you: finished its
/// turn (working → idle) or got blocked on a prompt (→ waiting). Clicking
/// one switches to that agent's pane, same as Return in the popover.
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

  private static let idleSettle: Duration = .seconds(3)
  private static let hasBundle = Bundle.main.bundleIdentifier != nil

  private enum Reason { case finished, blocked }

  init(scanner: AgentScanner, isPopoverShown: @escaping () -> Bool) {
    self.scanner = scanner
    self.isPopoverShown = isPopoverShown
    super.init()
    // Must be set before launch finishes, or a click that launched/
    // activated the app is delivered to nobody.
    if Self.hasBundle { UNUserNotificationCenter.current().delegate = self }
    subscription = scanner.$sessions.sink { [weak self] sessions in
      self?.observe(sessions)
    }
  }

  /// Asks for permission — called when the Settings toggle is switched on,
  /// not at launch, so the one-shot system prompt appears in response to
  /// something the user just did.
  static func requestAuthorization() {
    guard hasBundle else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, _ in
      DispatchQueue.main.async { AppSettings.shared.notificationsDenied = !granted }
    }
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

      switch session.status {
      case .waiting:
        cancelPending(key)
        post(session, reason: .blocked)
      case .idle where previous == .working:
        schedule(session, key: key)
      case .working:
        // Back at work: whatever we said about this pane is moot now.
        cancelPending(key)
        if Self.hasBundle {
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
        }
      default:
        break
      }
    }
    for key in lastStatus.keys where current[key] == nil { cancelPending(key) }
    lastStatus = current
    primed = true
  }

  private func schedule(_ session: AgentSession, key: String) {
    cancelPending(key)
    pendingIdle[key] = Task { [weak self] in
      try? await Task.sleep(for: Self.idleSettle)
      guard !Task.isCancelled, let self else { return }
      self.pendingIdle[key] = nil
      guard let latest = self.scanner.sessions.first(where: { Self.key($0) == key }),
        latest.status == .idle
      else { return }
      self.post(latest, reason: .finished)
    }
  }

  private func cancelPending(_ key: String) {
    pendingIdle.removeValue(forKey: key)?.cancel()
  }

  private func post(_ session: AgentSession, reason: Reason) {
    guard AppSettings.shared.notificationsEnabled, !isPopoverShown() else { return }
    let targetApp = AppSettings.shared.targetApp
    // Focus check and transcript read both touch tmux/disk — off main.
    Task.detached {
      if Self.isViewing(session, targetApp: targetApp) { return }
      let title = session.displayName
      let body: String
      switch reason {
      case .blocked:
        body = "Needs you — \(session.waitingFor ?? "blocked")"
      case .finished:
        body =
          Self.snippet(TranscriptPreview.details(for: session).text) ?? "Finished — awaiting you"
      }
      await MainActor.run { Self.deliver(session, title: title, body: body) }
    }
  }

  private static func deliver(_ session: AgentSession, title: String, body: String) {
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
    content.sound = .default
    content.threadIdentifier = session.paneId
    content.userInfo = ["paneId": session.paneId]
    // Same identifier per pane + pid, so a newer notification replaces an
    // older one for the same agent instead of stacking.
    let request = UNNotificationRequest(identifier: key(session), content: content, trigger: nil)
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
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if let paneId, let session = self.scanner.sessions.first(where: { $0.paneId == paneId }) {
          Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
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
