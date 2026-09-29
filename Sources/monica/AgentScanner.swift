import CoreServices
import Foundation

/// The aistatus file, still the only status source for `pi` (which has no
/// `~/.claude/sessions` registry). `claude` reads its status from the sessions
/// file instead — see `ClaudeSessionFile`/`lookupStatus`.
private struct AIStatusFile: Decodable {
  var sessionId: String?
  var pid: Int?
  var status: String?
  var project: String?
  var timestamp: Double?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case pid
    case status
    case project
    case timestamp
  }
}

/// Most-recently-updated first — the `.recency` `SortMode`'s comparator,
/// also reused as the tiebreak for every other mode.
private func newerFirst(_ a: AgentSession, _ b: AgentSession) -> Bool {
  (a.lastUpdated ?? .distantPast) > (b.lastUpdated ?? .distantPast)
}

/// Least-recently-updated first — the `.stalestFirst` `SortMode`'s
/// comparator, and `.needsAttention`'s tiebreak within its idle bucket.
private func olderFirst(_ a: AgentSession, _ b: AgentSession) -> Bool {
  (a.lastUpdated ?? .distantPast) < (b.lastUpdated ?? .distantPast)
}

/// Ports `,tmux-agent-scan` + the aistatus lookup from `,tmux-ai-agents` natively,
/// so monica has no runtime dependency on the dotfiles scripts.
///
/// Two kinds of scan, both run off the main thread on `queue` (a scan spawns
/// `tmux`/`ps` — ~60ms normally, 200ms+ under load, and unbounded if the tmux
/// server wedges — which used to block the UI every tick):
///
/// - **full**: `tmux list-panes` + `ps` pid-tree walk + status files. Runs on
///   the `pollInterval` timer, on popover open, and when a status file appears
///   or disappears for a pid we don't know about (a new/exited agent).
/// - **status**: re-reads only the status files for the agents the last full
///   scan found. Triggered by FSEvents on the two status directories, so a
///   working → idle flip shows up within ~100ms instead of up to a poll tick
///   later, without spawning any processes.
///
/// Requests coalesce: at most one scan is in flight, and requests arriving
/// meanwhile collapse into a single follow-up (full wins over status).
/// `sessions` is only reassigned when the result actually changed, so
/// SwiftUI observers don't re-render on every tick.
@MainActor
final class AgentScanner: ObservableObject {
  @Published private(set) var sessions: [AgentSession] = []

  enum ScanKind { case status, full }

  private var timer: Timer?
  private var watcher: StatusDirWatcher?
  private let queue = DispatchQueue(label: "com.meain.monica.scan", qos: .userInitiated)
  private var inFlight = false
  private var pending: ScanKind?
  /// What the last successful full scan found — the input to status-only
  /// refreshes. Main-actor only; handed to `queue` by value.
  private var agents: [ScanEngine.FoundAgent] = []
  /// `agents`' pids, for deciding whether a status-file event is for an
  /// agent we already know (status refresh) or a new/exited one (full scan).
  private var knownPids = Set<Int32>()

  func start(interval: TimeInterval = 2.0) {
    requestScan(.full)
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.requestScan(.full) }
    }
    if watcher == nil {
      watcher = StatusDirWatcher(paths: [ScanEngine.claudeSessionsDir, ScanEngine.statusDir]) {
        [weak self] paths in
        MainActor.assumeIsolated { self?.statusFilesChanged(paths) }
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    watcher = nil
  }

  func requestScan(_ kind: ScanKind = .full) {
    guard !inFlight else {
      pending = (pending == .full || kind == .full) ? .full : .status
      return
    }
    inFlight = true
    // Everything the background job needs from main-actor state is captured
    // here, by value — the job itself touches nothing shared.
    let input = ScanEngine.Input(
      kind: kind,
      previousAgents: agents,
      sortMode: AppSettings.shared.sortMode,
      lastActivated: Switcher.lastActivatedSnapshot()
    )
    queue.async { [weak self] in
      let output = ScanEngine.run(input)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finish(output) }
      }
    }
  }

  private func finish(_ output: ScanEngine.Output?) {
    inFlight = false
    // nil = tmux/ps didn't answer (timeout/launch failure): keep the previous
    // list rather than blanking every agent over one transient hiccup.
    if let output {
      if let found = output.agents {
        agents = found
        knownPids = Set(found.map(\.pid))
      }
      if output.sessions != sessions { sessions = output.sessions }
    }
    if let next = pending {
      pending = nil
      requestScan(next)
    }
  }

  /// FSEvents callback. `<pid>.json` (claude) / `pid-<pid>.json` (pi): a
  /// change for a known pid is a status refresh; anything else (a new agent
  /// registering, or an exited one's file being pruned) needs a full scan to
  /// re-walk the pid tree.
  private func statusFilesChanged(_ paths: [String]) {
    var kind: ScanKind?
    for path in paths {
      let name = (path as NSString).lastPathComponent
      guard name.hasSuffix(".json") else { continue }
      let stem = name.dropLast(5)
      let pidString = stem.hasPrefix("pid-") ? stem.dropFirst(4) : stem
      guard let pid = Int32(pidString) else { continue }
      let exists = FileManager.default.fileExists(atPath: path)
      if !knownPids.contains(pid) && exists || knownPids.contains(pid) && !exists {
        kind = .full
        break
      }
      kind = .status
    }
    if let kind { requestScan(kind) }
  }
}

/// The scan itself — pure functions of their input plus the filesystem/tmux,
/// no main-actor state, so it runs on `AgentScanner`'s background queue.
private enum ScanEngine {
  static let statusDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/aistatus").path
  static let claudeSessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/sessions").path

  /// A pane whose pid tree has a `claude`/`pi` process in it.
  struct FoundAgent {
    var pane: RawPane
    var pid: Int32
    var name: String
  }

  struct Input {
    var kind: AgentScanner.ScanKind
    var previousAgents: [FoundAgent]
    var sortMode: SortMode
    var lastActivated: [String: Date]
  }

  struct Output {
    /// Set by full scans only — status refreshes reuse the previous list.
    var agents: [FoundAgent]?
    var sessions: [AgentSession]
  }

  static func run(_ input: Input) -> Output? {
    var found = input.previousAgents
    var freshAgents: [FoundAgent]?
    if input.kind == .full {
      guard let panes = listPanes(), let tree = buildProcessTree() else { return nil }
      found = findAgents(panes: panes, tree: tree)
      freshAgents = found
    }

    var result = found.map { agent in
      let info = lookupStatus(
        pid: agent.pid, agentName: agent.name, fallbackPath: agent.pane.panePath)
      return AgentSession(
        paneId: agent.pane.paneId,
        windowId: agent.pane.windowId,
        session: agent.pane.session,
        windowName: agent.pane.windowName,
        panePath: agent.pane.panePath,
        agentPid: agent.pid,
        agentName: agent.name,
        status: info.status,
        project: info.project,
        lastUpdated: info.lastUpdated,
        sessionId: info.sessionId,
        customName: SessionNameStore.name(for: agent.pid),
        agentSessionName: info.agentSessionName,
        waitingFor: info.waitingFor
      )
    }
    let paneInfoByPaneId = Dictionary(
      found.map { ($0.pane.paneId, $0.pane) }, uniquingKeysWith: { first, _ in first })
    sort(&result, input: input, paneInfoByPaneId: paneInfoByPaneId)
    return Output(agents: freshAgents, sessions: result)
  }

  private static func findAgents(panes: [RawPane], tree: ProcessTree) -> [FoundAgent] {
    var seenPaneIds = Set<String>()
    var result: [FoundAgent] = []
    for pane in panes {
      // A window can be linked into multiple sessions (session groups),
      // so the same pane can appear more than once in `list-panes -a`.
      guard !seenPaneIds.contains(pane.paneId) else { continue }
      seenPaneIds.insert(pane.paneId)
      guard let agent = tree.findAgent(fromRoot: pane.panePid) else { continue }
      result.append(FoundAgent(pane: pane, pid: agent.pid, name: agent.name))
    }
    return result
  }

  /// Order is settings-driven (see `SortMode`) — read fresh each scan so a
  /// Settings change takes effect on the next tick without restarting.
  private static func sort(
    _ result: inout [AgentSession], input: Input, paneInfoByPaneId: [String: RawPane]
  ) {
    switch input.sortMode {
    case .recency:
      result.sort(by: newerFirst)
    case .statusPriority:
      result.sort {
        if $0.sortPriorityRank != $1.sortPriorityRank {
          return $0.sortPriorityRank > $1.sortPriorityRank
        }
        return newerFirst($0, $1)
      }
    case .stalestFirst:
      result.sort(by: olderFirst)
    case .alphabeticalProject:
      result.sort {
        let order = $0.project.localizedCaseInsensitiveCompare($1.project)
        if order != .orderedSame { return order == .orderedAscending }
        return newerFirst($0, $1)
      }
    case .groupedBySession:
      result.sort {
        let sessionOrder = $0.session.localizedCaseInsensitiveCompare($1.session)
        if sessionOrder != .orderedSame { return sessionOrder == .orderedAscending }
        let windowOrder = $0.windowName.localizedCaseInsensitiveCompare($1.windowName)
        if windowOrder != .orderedSame { return windowOrder == .orderedAscending }
        return newerFirst($0, $1)
      }
    case .groupedByAgentType:
      result.sort {
        let order = $0.agentName.localizedCaseInsensitiveCompare($1.agentName)
        if order != .orderedSame { return order == .orderedAscending }
        return newerFirst($0, $1)
      }
    case .tmux:
      let current = currentTmuxSession()
      result.sort {
        guard let p0 = paneInfoByPaneId[$0.paneId], let p1 = paneInfoByPaneId[$1.paneId] else {
          return newerFirst($0, $1)
        }
        let isCurrent0 = p0.session == current
        let isCurrent1 = p1.session == current
        if isCurrent0 != isCurrent1 { return isCurrent0 }
        if p0.session != p1.session {
          // Different sessions (neither is "current", or this is a tiebreak
          // that can't happen since only one session can equal `current`):
          // most-recently-attached session first.
          if p0.sessionLastAttached != p1.sessionLastAttached {
            return p0.sessionLastAttached > p1.sessionLastAttached
          }
          return p0.session.localizedCaseInsensitiveCompare(p1.session) == .orderedAscending
        }
        // Same session: tmux's own window/pane order.
        if p0.windowIndex != p1.windowIndex { return p0.windowIndex < p1.windowIndex }
        return p0.paneIndex < p1.paneIndex
      }
    case .needsAttention:
      result.sort {
        if $0.needsAttentionRank != $1.needsAttentionRank {
          return $0.needsAttentionRank > $1.needsAttentionRank
        }
        // Waiting/idle buckets (the top two): longest-waiting first — the
        // agent that's been awaiting you the longest. Every other bucket
        // falls back to plain recency.
        if $0.isAwaitingUser { return olderFirst($0, $1) }
        return newerFirst($0, $1)
      }
    case .yourActivity:
      result.sort {
        let a0 = input.lastActivated[$0.paneId] ?? .distantPast
        let a1 = input.lastActivated[$1.paneId] ?? .distantPast
        if a0 != a1 { return a0 > a1 }
        return newerFirst($0, $1)
      }
    }
  }

  // MARK: - tmux pane listing

  struct RawPane {
    var paneId: String
    var windowId: String
    var session: String
    var windowName: String
    var panePath: String
    var panePid: Int32
    /// tmux's own window/pane ordering — used by the `.tmux` `SortMode` to
    /// sort panes within a session the same way tmux itself lays them out.
    var windowIndex: Int
    var paneIndex: Int
    /// Unix timestamp of `#{session_last_attached}` — the `.tmux` `SortMode`'s
    /// proxy for "order of access" among sessions other than the current one.
    var sessionLastAttached: Double
  }

  /// nil only if tmux didn't answer at all (see `runCaptureChecked`); no
  /// server running is a real, empty answer.
  private static func listPanes() -> [RawPane]? {
    let format =
      "#{pane_id}\t#{window_id}\t#{?session_group,#{session_group},#{session_name}}\t#{window_name}\t#{pane_current_path}\t#{pane_pid}\t#{window_index}\t#{pane_index}\t#{session_last_attached}"
    guard let output = TmuxCLI.runChecked(["list-panes", "-a", "-F", format]) else { return nil }

    return output.split(separator: "\n").compactMap { line -> RawPane? in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 9, let pid = Int32(fields[5]),
        let windowIndex = Int(fields[6]), let paneIndex = Int(fields[7]),
        let sessionLastAttached = Double(fields[8])
      else { return nil }
      return RawPane(
        paneId: fields[0], windowId: fields[1], session: fields[2],
        windowName: fields[3], panePath: fields[4], panePid: pid,
        windowIndex: windowIndex, paneIndex: paneIndex,
        sessionLastAttached: sessionLastAttached
      )
    }
  }

  /// The tmux session the (single, per DESIGN.md's assumption) attached
  /// client is currently on — the `.tmux` `SortMode`'s notion of "current
  /// session". Same single-client assumption as `Switcher.firstAttachedClient`.
  private static func currentTmuxSession() -> String? {
    let output = TmuxCLI.run(["list-clients", "-F", "#{client_session}"])
    return output.split(separator: "\n").first.map(String.init)
  }

  // MARK: - pid tree (BFS for a `claude`/`pi` descendant)

  struct ProcessTree {
    var childrenByPid: [Int32: [Int32]] = [:]
    var nameByPid: [Int32: String] = [:]

    func findAgent(fromRoot root: Int32) -> (pid: Int32, name: String)? {
      var queue = [root]
      var index = 0
      while index < queue.count {
        let pid = queue[index]
        index += 1
        if let name = nameByPid[pid], name == "claude" || name == "pi" {
          return (pid, name)
        }
        if let kids = childrenByPid[pid] {
          queue.append(contentsOf: kids)
        }
      }
      return nil
    }
  }

  private static func buildProcessTree() -> ProcessTree? {
    guard let output = runCaptureChecked("/bin/ps", ["-Ao", "pid,ppid,comm"]) else { return nil }
    var tree = ProcessTree()
    for line in output.split(separator: "\n").dropFirst() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
        continue
      }
      let name =
        (parts[2] as Substring).split(separator: "/").last.map(String.init) ?? String(parts[2])
      tree.nameByPid[pid] = name
      tree.childrenByPid[ppid, default: []].append(pid)
    }
    return tree
  }

  // MARK: - status lookup

  struct StatusInfo {
    var status: AgentStatus
    var project: String
    var lastUpdated: Date?
    var sessionId: String?
    var agentSessionName: String?
    var waitingFor: String?

    static func missing(fallbackPath: String) -> StatusInfo {
      StatusInfo(status: .idle, project: (fallbackPath as NSString).lastPathComponent)
    }
  }

  ///
  /// `claude` reads everything from `~/.claude/sessions/<pid>.json` — Claude
  /// Code's own live process registry, which is fresher and more reliable
  /// than the hook-driven aistatus file (it's written by the CLI itself, not
  /// by a hook that has to fire). `pi` has no such registry, so it still reads
  /// the aistatus file.
  ///
  /// No age cutoff here (unlike `,tmux-ai-agents`'s 2h `STALE_SECS`, which
  /// just falls back to a plain "idle" once a file is old) — the pid tree
  /// scan already guarantees this pid is a still-live process, so an old
  /// timestamp is a meaningful "hasn't updated in a while" signal, not
  /// stale/wrong data. `AgentSession.isQuiet`/`isStale` decide how that's
  /// drawn, at the display layer, not here.
  private static func lookupStatus(pid: Int32, agentName: String, fallbackPath: String)
    -> StatusInfo
  {
    if agentName == "claude" {
      return lookupClaudeStatus(pid: pid, fallbackPath: fallbackPath)
    }

    let file = URL(fileURLWithPath: statusDir).appendingPathComponent("pid-\(pid).json")
    guard let data = try? Data(contentsOf: file),
      let parsed = try? JSONDecoder().decode(AIStatusFile.self, from: data),
      let ts = parsed.timestamp
    else {
      return .missing(fallbackPath: fallbackPath)
    }

    // Only "working" maps to `.working`; everything else collapses to
    // `.idle` — including aistatus's "waiting", which comes from a hook
    // that isn't a reliable "blocked" signal (unlike Claude's registry).
    let status: AgentStatus = parsed.status == "working" ? .working : .idle
    let project = parsed.project ?? (fallbackPath as NSString).lastPathComponent
    return StatusInfo(
      status: status, project: project, lastUpdated: Date(timeIntervalSince1970: ts),
      sessionId: parsed.sessionId)
  }

  /// Claude Code maintains `~/.claude/sessions/<pid>.json` per live process
  /// (pruned when the process exits — confirmed against real files on this
  /// machine: only the currently-running pids exist). Claude Code (2.1.284)
  /// validates `status` as one of `busy` (running a task), `shell`, `idle`
  /// (finished its turn, at the prompt), and `waiting` (blocked mid-task on
  /// a permission prompt/dialog/elicitation). `waitingFor` is set only
  /// alongside `waiting` — reasons seen in the binary: "input needed",
  /// "dialog open", "sandbox request", "worker request", "goal proposal".
  /// `busy` → `.working`, `waiting` → `.waiting`, anything else → `.idle`.
  /// `updatedAt`/`statusUpdatedAt`
  /// are epoch *milliseconds*. `name` is the session's title, but
  /// `nameSource: "derived"` marks an auto-generated placeholder (just the
  /// cwd's last component plus a hash suffix, e.g. "monica-dd") — those are
  /// skipped, since showing one would be strictly noisier than the plain
  /// project name it's derived from. Explicitly named sessions carry no
  /// `nameSource` field.
  private struct ClaudeSessionFile: Decodable {
    var status: String?
    var cwd: String?
    var sessionId: String?
    var updatedAt: Double?
    var statusUpdatedAt: Double?
    var name: String?
    var nameSource: String?
    var waitingFor: String?
  }

  private static func lookupClaudeStatus(pid: Int32, fallbackPath: String) -> StatusInfo {
    let file = URL(fileURLWithPath: claudeSessionsDir).appendingPathComponent("\(pid).json")
    guard let data = try? Data(contentsOf: file),
      let parsed = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    else {
      return .missing(fallbackPath: fallbackPath)
    }

    let status: AgentStatus
    switch parsed.status {
    case "busy": status = .working
    case "waiting": status = .waiting
    default: status = .idle
    }
    let project =
      (parsed.cwd as NSString?)?.lastPathComponent
      ?? (fallbackPath as NSString).lastPathComponent
    // Most-recent registry write is the best "last active" proxy — see the
    // doc comment above; the two timestamps are usually equal but take the max.
    let lastUpdated = [parsed.updatedAt, parsed.statusUpdatedAt].compactMap { $0 }.max()
      .map { Date(timeIntervalSince1970: $0 / 1000) }
    let agentSessionName: String? = {
      guard parsed.nameSource != "derived", let name = parsed.name, !name.isEmpty else {
        return nil
      }
      return name
    }()
    return StatusInfo(
      status: status, project: project, lastUpdated: lastUpdated, sessionId: parsed.sessionId,
      agentSessionName: agentSessionName,
      waitingFor: status == .waiting ? parsed.waitingFor : nil)
  }
}

/// File-level FSEvents on the status directories, delivered on the main
/// queue with ~100ms coalescing. FSEvents rather than a `DispatchSource` on
/// the directory fd: a directory source only fires on entries being
/// added/removed/renamed, not on an existing file being rewritten in place,
/// and which of those the status writers do isn't something to depend on.
private final class StatusDirWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: ([String]) -> Void

  init?(paths: [String], onChange: @escaping ([String]) -> Void) {
    self.onChange = onChange
    var context = FSEventStreamContext(
      version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<StatusDirWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
      watcher.onChange(Array(paths.prefix(count)))
    }
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagUseCFTypes)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
