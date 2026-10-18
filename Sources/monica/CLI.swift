import Foundation

/// Command-line front end, built into the same binary: `monica <command>`
/// runs a command and exits, bare `monica` launches the menu bar app. It
/// scans tmux directly (same engine as the app), so it works whether or not
/// the app is running — there is no IPC.
enum MonicaCLI {
  static let usage = """
    usage: monica <command> [options]

    commands:
      ls [--json] [--status working|idle|waiting|quiet|stale]
                                list running agents
      show <target> [--json]    details + last message of one agent
      focus <target>            switch tmux to the agent's pane and raise the terminal
      tail <target> [-n N]      last N (default 20) lines on the agent's screen
      send <target> [text…]     paste text + Enter into the pane (stdin if no text, or "-")
           [--wait] [--timeout SECS] [--grace SECS]
                                then block until the agent finishes its turn; if no turn
                                starts within the grace period (default 5s, e.g. /clear)
                                return right away. Refuses your own pane unless --force.
      wait <target> [--timeout SECS]   block until the agent is not working

    <target> is a pane id (%12), an agent pid, or a case-insensitive substring of
    the agent's name/project/tmux session/window. It must match exactly one agent.

    exit codes: 0 ok, 1 error, 2 usage, 3 agent is waiting on you (wait/send --wait),
    124 timed out
    """

  /// Returns an exit code if `args` is a CLI invocation, nil to launch the app.
  static func runIfRequested(_ args: [String]) -> Int32? {
    let rest = args.dropFirst().filter { !$0.hasPrefix("-psn") }
    guard let command = rest.first else { return nil }
    SessionNameStore.readDomain = "com.meain.monica"
    return run(command, Array(rest.dropFirst()))
  }

  private static func run(_ command: String, _ args: [String]) -> Int32 {
    switch command {
    case "ls", "list": return list(args)
    case "show": return show(args)
    case "focus": return focus(args)
    case "tail": return tail(args)
    case "send": return send(args)
    case "wait": return wait(args)
    case "help", "-h", "--help":
      print(usage)
      return 0
    default:
      return fail("unknown command '\(command)'\n\n\(usage)", code: 2)
    }
  }

  // MARK: - Commands

  private static func list(_ args: [String]) -> Int32 {
    var opts = Options(args)
    let json = opts.flag("--json")
    let status = opts.value("--status")
    if let bad = opts.unexpected { return fail("unknown option '\(bad)'", code: 2) }
    guard var sessions = scan() else { return fail("tmux did not respond") }
    if let status { sessions = sessions.filter { $0.stateName == status } }

    if json {
      printJSON(sessions.map(jsonObject))
      return 0
    }
    let rows = sessions.map { s in
      [
        s.paneId, s.stateName, s.agentName, "\(s.session):\(s.windowName)",
        s.displayName + (isSelf(s) ? " (you)" : ""), s.lastUpdatedDisplay,
      ]
    }
    printTable(["PANE", "STATE", "AGENT", "WINDOW", "NAME", "UPDATED"], rows)
    return 0
  }

  private static func show(_ args: [String]) -> Int32 {
    var opts = Options(args)
    let json = opts.flag("--json")
    guard let target = opts.positional.first else { return fail("show: missing <target>", code: 2) }
    if let bad = opts.unexpected { return fail("unknown option '\(bad)'", code: 2) }
    let session: AgentSession
    switch resolve(target) {
    case .success(let s): session = s
    case .failure(let message): return fail(message)
    }
    var details = TranscriptPreview.details(for: session)
    // The preview's placeholders ("(preview unavailable)", "(no session id…)")
    // mean there's no transcript text — a fresh or just-cleared session.
    // Say so and show the screen instead.
    var screen: [String]?
    if details.text?.hasPrefix("(") == true {
      details.text = nil
      screen = paneLines(session.paneId, count: 10)
    }

    if json {
      var obj = jsonObject(session)
      obj["gitBranch"] = details.gitBranch
      obj["model"] = details.model
      obj["lastPrompt"] = details.lastPrompt
      obj["toolActivity"] = details.toolActivity
      obj["lastMessage"] = details.text
      obj["screen"] = screen
      printJSON(obj)
      return 0
    }
    var fields: [(String, String?)] = [
      ("name", session.displayName),
      ("state", session.stateName + (session.waitingFor.map { " (\($0))" } ?? "")),
      ("agent", "\(session.agentName) (pid \(session.agentPid))"),
      ("pane", "\(session.paneId)  \(session.session):\(session.windowName)"),
      ("path", session.panePath),
      ("updated", session.lastUpdatedDisplay),
      ("branch", details.gitBranch),
      ("model", details.model),
      ("tool", details.toolActivity),
      ("prompt", details.lastPrompt),
    ]
    fields.removeAll { $0.1 == nil }
    for (key, value) in fields { print("\(key.padding(toLength: 8, withPad: " ", startingAt: 0))\(value!)") }
    if let text = details.text {
      print("\n\(text)")
    } else if let screen {
      print("\n(session has no messages yet — last \(screen.count) lines of the pane)")
      for line in screen { print(line) }
    }
    return 0
  }

  private static func tail(_ args: [String]) -> Int32 {
    var opts = Options(args)
    let count = opts.value("-n").flatMap(Int.init) ?? 20
    guard let target = opts.positional.first else { return fail("tail: missing <target>", code: 2) }
    switch resolve(target) {
    case .failure(let message): return fail(message)
    case .success(let session):
      for line in paneLines(session.paneId, count: count) { print(line) }
      return 0
    }
  }

  /// The last `count` lines of what's on the pane's screen, trailing blank
  /// lines dropped (the visible area is padded to the pane height).
  private static func paneLines(_ paneId: String, count: Int) -> [String] {
    var lines = TmuxCLI.run(["capture-pane", "-p", "-t", paneId])
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    return Array(lines.suffix(max(count, 0)))
  }

  private static func focus(_ args: [String]) -> Int32 {
    guard let target = args.first else { return fail("focus: missing <target>", code: 2) }
    switch resolve(target) {
    case .failure(let message): return fail(message)
    case .success(let session):
      let app = persistedTargetApp()
      Switcher.activate(session, targetApp: app)
      return 0
    }
  }

  private static func send(_ args: [String]) -> Int32 {
    var opts = Options(args)
    let wait = opts.flag("--wait")
    let force = opts.flag("--force")
    let timeout = opts.value("--timeout").flatMap(Double.init)
    let grace = opts.value("--grace").flatMap(Double.init) ?? 5
    guard let target = opts.positional.first else { return fail("send: missing <target>", code: 2) }
    if let bad = opts.unexpected { return fail("unknown option '\(bad)'", code: 2) }

    var words = Array(opts.positional.dropFirst())
    if words.isEmpty || words == ["-"] {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      words = [String(decoding: data, as: UTF8.self)]
    }
    // Drop trailing newlines — sendMessage adds its own Enter.
    var text = words.joined(separator: " ")
    while text.hasSuffix("\n") { text.removeLast() }
    guard !text.isEmpty else { return fail("send: nothing to send", code: 2) }

    let session: AgentSession
    switch resolve(target) {
    case .success(let s): session = s
    case .failure(let message): return fail(message)
    }
    if isSelf(session) && !force {
      return fail("\(session.paneId) is your own pane; refusing to send (use --force to override)")
    }
    Switcher.sendMessage(session, text: text)
    SendLog.record(session)
    guard wait else { return 0 }
    // Done once the registry has been touched *after* our send and the agent
    // is no longer busy; otherwise an immediate poll would still see the
    // pre-send "idle".
    return waitLoop(paneId: session.paneId, since: Date(), timeout: timeout, grace: grace)
  }

  private static func wait(_ args: [String]) -> Int32 {
    var opts = Options(args)
    let timeout = opts.value("--timeout").flatMap(Double.init)
    guard let target = opts.positional.first else { return fail("wait: missing <target>", code: 2) }
    if let bad = opts.unexpected { return fail("unknown option '\(bad)'", code: 2) }
    switch resolve(target) {
    case .failure(let message): return fail(message)
    case .success(let session):
      return waitLoop(paneId: session.paneId, since: nil, timeout: timeout)
    }
  }

  /// Polls until the agent is not working (and, with `since`, has updated
  /// after that moment). 0 = idle, 3 = waiting on the user, 124 = timeout,
  /// 1 = the agent disappeared.
  private static func waitLoop(
    paneId: String, since: Date?, timeout: Double?, grace: Double = 0
  ) -> Int32 {
    let start = Date()
    let deadline = timeout.map { start.addingTimeInterval($0) }
    var sawWorking = false
    while true {
      // `scan()` folds in our own send time, so look at the raw registry
      // time here — otherwise "advanced" would be true the moment we sent.
      if let sessions = scanAgentsOnce() {
        guard let s = sessions.first(where: { $0.paneId == paneId }) else {
          return fail("agent in \(paneId) is gone")
        }
        if s.status == .working { sawWorking = true }
        let advanced = since.map { ($0 < (s.lastUpdated ?? .distantPast)) || sawWorking } ?? true
        if s.status == .waiting { return 3 }
        if s.status != .working && advanced { return 0 }
        // Slash commands (/clear, /compact) are handled without a turn, so
        // the agent never shows as working. No turn after the grace period
        // → assume the input was consumed.
        if since != nil, grace > 0, !sawWorking, !advanced,
          Date().timeIntervalSince(start) >= grace
        {
          FileHandle.standardError.write(
            Data("monica: no turn started within \(Int(grace))s; assuming input was handled\n".utf8))
          return 0
        }
      }
      if let deadline, Date() >= deadline { return 124 }
      Thread.sleep(forTimeInterval: 1)
    }
  }

  // MARK: - Target resolution

  private enum Resolution {
    case success(AgentSession)
    case failure(String)
  }

  /// `$TMUX_PANE` is the caller's own pane; unset means the caller isn't in
  /// tmux, so no listed pane is "you".
  private static func isSelf(_ s: AgentSession) -> Bool {
    ProcessInfo.processInfo.environment["TMUX_PANE"] == s.paneId
  }

  /// `scanAgentsOnce()` plus the time of our own last `send` to each pane.
  /// Input that doesn't start a turn (/clear, /compact) never produces a
  /// status update, so without this a pane we just typed into would keep
  /// reading quiet/stale with an old `updated` time.
  private static func scan() -> [AgentSession]? {
    guard var sessions = scanAgentsOnce() else { return nil }
    let sent = SendLog.load()
    for i in sessions.indices {
      if let at = sent[SendLog.key(sessions[i])],
        at > (sessions[i].lastUpdated ?? .distantPast)
      {
        sessions[i].lastUpdated = at
      }
    }
    return sessions
  }

  private static func resolve(_ target: String) -> Resolution {
    guard let sessions = scan() else { return .failure("tmux did not respond") }
    if let exact = sessions.first(where: { $0.paneId == target || String($0.agentPid) == target }) {
      return .success(exact)
    }
    let needle = target.lowercased()
    let matches = sessions.filter { s in
      [s.displayName, s.project, s.session, s.windowName]
        .contains { $0.lowercased().contains(needle) }
    }
    switch matches.count {
    case 1: return .success(matches[0])
    case 0: return .failure("no agent matches '\(target)' (try `monica ls`)")
    default:
      let list = matches.map { "  \($0.paneId)  \($0.session):\($0.windowName)  \($0.displayName)" }
      return .failure(
        "'\(target)' is ambiguous, matches:\n" + list.joined(separator: "\n"))
    }
  }

  private static func persistedTargetApp() -> String {
    let domain = UserDefaults.standard.persistentDomain(forName: "com.meain.monica")
    return domain?["monica.targetApp"] as? String ?? "Ghostty"
  }

  // MARK: - Output

  private static func jsonObject(_ s: AgentSession) -> [String: Any?] {
    [
      "pane": s.paneId,
      "window": s.windowId,
      "tmuxSession": s.session,
      "windowName": s.windowName,
      "path": s.panePath,
      "pid": Int(s.agentPid),
      "agent": s.agentName,
      "state": s.stateName,
      "status": s.status.rawValue,
      "waitingFor": s.waitingFor,
      "name": s.displayName,
      "project": s.project,
      "sessionId": s.sessionId,
      "updatedAt": s.lastUpdated.map { ISO8601DateFormatter().string(from: $0) },
      "isSelf": isSelf(s),
    ]
  }

  private static func printJSON(_ value: Any) {
    func clean(_ v: Any) -> Any {
      if let dict = v as? [String: Any?] {
        return dict.mapValues { $0.map(clean) ?? NSNull() }
      }
      if let array = v as? [Any] { return array.map(clean) }
      return v
    }
    let data = try? JSONSerialization.data(
      withJSONObject: clean(value), options: [.prettyPrinted, .sortedKeys])
    print(data.map { String(decoding: $0, as: UTF8.self) } ?? "null")
  }

  private static func printTable(_ header: [String], _ rows: [[String]]) {
    guard !rows.isEmpty else {
      FileHandle.standardError.write(Data("no agents running\n".utf8))
      return
    }
    let all = [header] + rows
    let widths = header.indices.map { col in all.map { $0[col].count }.max() ?? 0 }
    for row in all {
      let line = row.enumerated().map { i, cell in
        i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
      }
      print(line.joined(separator: "  "))
    }
  }

  @discardableResult
  private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
    FileHandle.standardError.write(Data("monica: \(message)\n".utf8))
    return code
  }
}

/// When the CLI last typed into each pane, keyed by pane id + agent pid (so a
/// reused pane id doesn't inherit it). A small JSON file, since every CLI
/// invocation is a separate process. Best-effort: I/O failures are ignored.
private enum SendLog {
  private static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/monica/last-sent.json")

  static func key(_ s: AgentSession) -> String { "\(s.paneId):\(s.agentPid)" }

  static func load() -> [String: Date] {
    guard let data = try? Data(contentsOf: url),
      let raw = try? JSONDecoder().decode([String: Double].self, from: data)
    else { return [:] }
    return raw.mapValues { Date(timeIntervalSince1970: $0) }
  }

  static func record(_ s: AgentSession) {
    var raw = load().mapValues { $0.timeIntervalSince1970 }
    // Entries older than a day are for agents long gone.
    raw = raw.filter { Date().timeIntervalSince1970 - $0.value < 86_400 }
    raw[key(s)] = Date().timeIntervalSince1970
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(raw).write(to: url, options: .atomic)
  }
}

/// Tiny argv helper: `--flag`, `--key value`, and the leftover positionals.
private struct Options {
  private var args: [String]
  init(_ args: [String]) { self.args = args }

  mutating func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
  }

  mutating func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
  }

  /// Leftover `--option` that no one consumed. Only checked before the
  /// positionals are read, so message text starting with `-` after the
  /// target (`send x -- -foo`) isn't mistaken for one: stop at `--`.
  var unexpected: String? {
    for a in args {
      if a == "--" { return nil }
      if a.hasPrefix("--") { return a }
    }
    return nil
  }

  var positional: [String] { args.filter { $0 != "--" } }
}

extension AgentSession {
  /// The effective state as the UI shows it: staleness overrides status.
  var stateName: String {
    if status == .waiting { return "waiting" }
    if isStale { return "stale" }
    if isQuiet { return "quiet" }
    return status.rawValue
  }
}
