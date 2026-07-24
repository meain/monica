import Foundation

private struct AIStatusFile: Decodable {
  var sessionId: String?
  var pid: Int?
  var status: String?
  var hookEvent: String?
  var project: String?
  var timestamp: Double?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case pid
    case status
    case hookEvent = "hook_event"
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
/// comparator, and `.needsAttention`'s tiebreak within its waiting bucket.
private func olderFirst(_ a: AgentSession, _ b: AgentSession) -> Bool {
  (a.lastUpdated ?? .distantPast) < (b.lastUpdated ?? .distantPast)
}

/// Ports `,tmux-agent-scan` + the aistatus lookup from `,tmux-ai-agents` natively,
/// so monica has no runtime dependency on the dotfiles scripts.
@MainActor
final class AgentScanner: ObservableObject {
  @Published var sessions: [AgentSession] = []

  private var timer: Timer?
  private let statusDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/aistatus")
  private let claudeSessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/sessions")

  func start(interval: TimeInterval = 2.0) {
    scan()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scan() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func scan() {
    let panes = listPanes()
    guard !panes.isEmpty else {
      sessions = []
      return
    }

    // `uniquingKeysWith:` (not `uniqueKeysWithValues:`) since a window linked
    // into multiple sessions (session groups) makes the same pane_id appear
    // more than once in `list-panes -a` — see the loop below.
    let paneInfoByPaneId = Dictionary(
      panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
    let tree = buildProcessTree()
    var seenPaneIds = Set<String>()
    var result: [AgentSession] = []

    for pane in panes {
      // A window can be linked into multiple sessions (session groups),
      // so the same pane can appear more than once in `list-panes -a`.
      guard !seenPaneIds.contains(pane.paneId) else { continue }
      seenPaneIds.insert(pane.paneId)

      guard let agent = tree.findAgent(fromRoot: pane.panePid) else { continue }

      let (status, project, lastUpdated, sessionId) = lookupStatus(
        pid: agent.pid, fallbackPath: pane.panePath)
      result.append(
        AgentSession(
          paneId: pane.paneId,
          windowId: pane.windowId,
          session: pane.session,
          windowName: pane.windowName,
          panePath: pane.panePath,
          agentPid: agent.pid,
          agentName: agent.name,
          status: status,
          project: project,
          lastUpdated: lastUpdated,
          sessionId: sessionId,
          customName: SessionNameStore.name(for: agent.pid),
          agentSessionName: agent.name == "claude" ? lookupClaudeSessionName(pid: agent.pid) : nil
        )
      )
    }

    // Order is settings-driven (see `SortMode`) — read fresh each scan so a
    // Settings change takes effect on the next tick without restarting.
    switch AppSettings.shared.sortMode {
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
        // Waiting bucket (rank 2): longest-waiting first — most overdue
        // for a response. Every other bucket falls back to plain recency.
        if $0.needsAttentionRank == 2 { return olderFirst($0, $1) }
        return newerFirst($0, $1)
      }
    case .yourActivity:
      result.sort {
        let a0 = Switcher.lastActivated($0.paneId) ?? .distantPast
        let a1 = Switcher.lastActivated($1.paneId) ?? .distantPast
        if a0 != a1 { return a0 > a1 }
        return newerFirst($0, $1)
      }
    }
    sessions = result
  }

  // MARK: - tmux pane listing

  private struct RawPane {
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

  private func listPanes() -> [RawPane] {
    let format =
      "#{pane_id}\t#{window_id}\t#{?session_group,#{session_group},#{session_name}}\t#{window_name}\t#{pane_current_path}\t#{pane_pid}\t#{window_index}\t#{pane_index}\t#{session_last_attached}"
    let output = TmuxCLI.run(["list-panes", "-a", "-F", format])
    guard !output.isEmpty else { return [] }

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
  private func currentTmuxSession() -> String? {
    let output = TmuxCLI.run(["list-clients", "-F", "#{client_session}"])
    return output.split(separator: "\n").first.map(String.init)
  }

  // MARK: - pid tree (BFS for a `claude`/`pi` descendant)

  private struct ProcessTree {
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

  private func buildProcessTree() -> ProcessTree {
    let output = runCapture("/bin/ps", ["-Ao", "pid,ppid,comm"])
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

  // MARK: - aistatus lookup

  /// No age cutoff here (unlike `,tmux-ai-agents`'s 2h `STALE_SECS`,
  /// which just falls back to a plain "idle" once a file is old) — the pid
  /// tree scan already guarantees this pid is a still-live process, so an
  /// old timestamp is a meaningful "hasn't updated in a while" signal, not
  /// stale/wrong data. `AgentSession.isStale` (>3h) decides how that's
  /// drawn, at the display layer, not here.
  private func lookupStatus(pid: Int32, fallbackPath: String) -> (
    AgentStatus, String, Date?, String?
  ) {
    let file = statusDir.appendingPathComponent("pid-\(pid).json")
    guard let data = try? Data(contentsOf: file),
      let parsed = try? JSONDecoder().decode(AIStatusFile.self, from: data),
      let ts = parsed.timestamp
    else {
      return (.idle, (fallbackPath as NSString).lastPathComponent, nil, nil)
    }

    let status = AgentStatus(rawValue: parsed.status ?? "idle") ?? .idle
    let project = parsed.project ?? (fallbackPath as NSString).lastPathComponent
    return (status, project, Date(timeIntervalSince1970: ts), parsed.sessionId)
  }

  // MARK: - Claude session name lookup

  /// Claude Code maintains `~/.claude/sessions/<pid>.json` per live process
  /// (pruned when the process exits — confirmed against real files on this
  /// machine: only the currently-running pids exist). `name` is the session's
  /// title, but `nameSource: "derived"` marks an auto-generated placeholder
  /// (just the cwd's last component plus a hash suffix, e.g. "monica-dd") —
  /// those are skipped, since showing one would be strictly noisier than the
  /// plain project name it's derived from. Explicitly named sessions carry no
  /// `nameSource` field.
  private struct ClaudeSessionFile: Decodable {
    var name: String?
    var nameSource: String?
  }

  private func lookupClaudeSessionName(pid: Int32) -> String? {
    let file = claudeSessionsDir.appendingPathComponent("\(pid).json")
    guard let data = try? Data(contentsOf: file),
      let parsed = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data),
      parsed.nameSource != "derived",
      let name = parsed.name, !name.isEmpty
    else { return nil }
    return name
  }
}
