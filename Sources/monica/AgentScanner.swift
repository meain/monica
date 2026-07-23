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
          customName: SessionNameStore.name(for: agent.pid)
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
  }

  private func listPanes() -> [RawPane] {
    let format =
      "#{pane_id}\t#{window_id}\t#{?session_group,#{session_group},#{session_name}}\t#{window_name}\t#{pane_current_path}\t#{pane_pid}"
    let output = TmuxCLI.run(["list-panes", "-a", "-F", format])
    guard !output.isEmpty else { return [] }

    return output.split(separator: "\n").compactMap { line -> RawPane? in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 6, let pid = Int32(fields[5]) else { return nil }
      return RawPane(
        paneId: fields[0], windowId: fields[1], session: fields[2],
        windowName: fields[3], panePath: fields[4], panePid: pid
      )
    }
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
}
