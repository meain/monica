import Foundation

private struct AIStatusFile: Decodable {
  var session_id: String?
  var pid: Int?
  var status: String?
  var hook_event: String?
  var project: String?
  var timestamp: Double?
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
          sessionId: sessionId
        )
      )
    }

    // Most recently updated first, matching the picker's sort order.
    result.sort { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
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
    return (status, project, Date(timeIntervalSince1970: ts), parsed.session_id)
  }
}
