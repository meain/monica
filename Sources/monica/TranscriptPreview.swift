import Foundation

/// Everything `TranscriptPreview` can pull out of a transcript for the
/// popover's "LAST MESSAGE" panel. `text` is nil only when nothing has been
/// looked up yet (no session selected) — once a session is selected it's
/// always a display-ready string (real content or a placeholder like
/// "(preview unavailable)"), matching the old `preview(for:)` contract so
/// `AgentPickerModel`'s "no agent selected" check still just tests for nil.
/// The other fields are best-effort extras and stay nil whenever the source
/// data doesn't have them (e.g. pi sessions never carry a git branch).
struct TranscriptDetails: Equatable {
  var text: String?
  var gitBranch: String?
  var model: String?
  var lastPrompt: String?
  var toolActivity: String?

  /// True once every field a given source can possibly fill in has been
  /// found, so the reverse scan can stop early instead of reading the whole
  /// tail on every lookup.
  fileprivate var isComplete: Bool {
    text != nil && gitBranch != nil && model != nil && lastPrompt != nil && toolActivity != nil
  }
}

/// Reads the last thing an agent actually said, straight from its own
/// transcript file — no extra tracking of our own, just parsing the same
/// on-disk format each agent already writes.
///
/// Claude Code: `~/.claude/projects/<cwd, every non-alphanumeric char -> '-'>/<sessionId>.jsonl`,
/// one JSON object per line, `type: "assistant"` entries with
/// `message.content` blocks of type `text`/`thinking`/`tool_use`. Confirmed
/// against real transcripts on this machine and matches
/// `~/.dotfiles/claude/.claude/hooks/notify-summary.sh`'s own extraction
/// (search backward for the last assistant message, join its `text` blocks).
/// Every line also carries a top-level `gitBranch` (can legitimately be the
/// literal string "HEAD" for a detached/colocated jj repo — shown as-is, not
/// specially cased), and assistant lines carry `message.model`. A separate
/// `type: "last-prompt"` line holds the most recent user prompt verbatim in
/// `lastPrompt`, which is simpler and more current than digging the last
/// `user`-role message out of content blocks.
///
/// pi: `~/.pi/agent/sessions/<"-" + cwd.replacingOccurrences(of: "/", with: "-") + "--">/`,
/// then either a flat `<timestamp>_<sessionId>.jsonl` file directly in that
/// directory (the common case), or — for sessions that got resumed/branched —
/// a `<timestamp>_<sessionId>` *directory* holding nested
/// `<hash>/run-N/session.jsonl` files instead, in which case the most
/// recently modified one is used. Confirmed both shapes exist side by side on
/// this machine. Each line has `message.role`/`message.content` with block
/// types `text`/`thinking`/`toolCall`, and assistant messages carry
/// `message.model`/`message.provider`. pi has no per-message git branch, so
/// `gitBranch` always stays nil for pi sessions. Best-effort: pi's format is
/// a branching id/parentId tree (see https://pi.dev/docs/latest/session-format)
/// and this deliberately ignores branches, just reading file order.
enum TranscriptPreview {
  private static let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")
  private static let piSessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".pi/agent/sessions")

  /// Only reads the tail of the transcript, not the whole (potentially
  /// multi-MB, long-running-session) file.
  private static let tailBytes = 200_000

  static func details(for session: AgentSession) -> TranscriptDetails {
    guard let sessionId = session.sessionId, !sessionId.isEmpty else {
      return TranscriptDetails(text: "(no session id in status file)")
    }
    var result: TranscriptDetails
    switch session.agentName {
    case "claude":
      result = claudeDetails(sessionId: sessionId, cwd: session.panePath) ?? TranscriptDetails()
    case "pi":
      result = piDetails(sessionId: sessionId, cwd: session.panePath) ?? TranscriptDetails()
    default:
      result = TranscriptDetails()
    }
    if result.text == nil { result.text = "(preview unavailable)" }
    return result
  }

  // MARK: - Claude Code

  private static func claudeEncode(_ path: String) -> String {
    String(
      path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
  }

  private static func claudeDetails(sessionId: String, cwd: String) -> TranscriptDetails? {
    let file =
      claudeProjectsDir
      .appendingPathComponent(claudeEncode(cwd))
      .appendingPathComponent("\(sessionId).jsonl")
    guard let lines = tailLines(of: file) else { return nil }

    var details = TranscriptDetails()
    for line in lines.reversed() {
      guard let obj = jsonObject(line) else { continue }

      if details.gitBranch == nil, let branch = obj["gitBranch"] as? String, !branch.isEmpty {
        details.gitBranch = branch
      }

      if obj["type"] as? String == "last-prompt", details.lastPrompt == nil {
        details.lastPrompt = obj["lastPrompt"] as? String
      }

      if obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any] {
        if details.model == nil { details.model = message["model"] as? String }
        if let content = message["content"] as? [[String: Any]] {
          if details.text == nil {
            let text = textBlocks(content)
            if !text.isEmpty { details.text = text }
          }
          if details.toolActivity == nil,
            let toolBlock = content.first(where: { $0["type"] as? String == "tool_use" })
          {
            details.toolActivity = toolSummary(
              name: toolBlock["name"] as? String, args: toolBlock["input"] as? [String: Any])
          }
        }
      }

      if details.isComplete { break }
    }
    return details
  }

  // MARK: - pi

  private static func piDetails(sessionId: String, cwd: String) -> TranscriptDetails? {
    let encodedDir = "-" + cwd.replacingOccurrences(of: "/", with: "-") + "--"
    let projectDir = piSessionsDir.appendingPathComponent(encodedDir)
    guard let file = latestPiSessionFile(under: projectDir, sessionId: sessionId),
      let lines = tailLines(of: file)
    else { return nil }

    var details = TranscriptDetails()
    for line in lines.reversed() {
      guard let obj = jsonObject(line), obj["type"] as? String == "message",
        let message = obj["message"] as? [String: Any]
      else { continue }

      if details.model == nil { details.model = message["model"] as? String }
      guard let content = message["content"] as? [[String: Any]] else { continue }

      switch message["role"] as? String {
      case "assistant":
        if details.text == nil {
          let text = textBlocks(content)
          if !text.isEmpty { details.text = text }
        }
        if details.toolActivity == nil,
          let toolBlock = content.first(where: { $0["type"] as? String == "toolCall" })
        {
          details.toolActivity = toolSummary(
            name: toolBlock["name"] as? String, args: toolBlock["arguments"] as? [String: Any])
        }
      case "user":
        if details.lastPrompt == nil {
          let text = textBlocks(content)
          if !text.isEmpty { details.lastPrompt = text }
        }
      default: break
      }

      // pi sessions never carry a git branch, so `isComplete` never counts
      // it — checking for it here would make every pi session scan the
      // whole tail before giving up.
      if details.text != nil, details.model != nil, details.lastPrompt != nil,
        details.toolActivity != nil
      {
        break
      }
    }
    return details
  }

  // MARK: - tool call summaries

  /// Common argument keys across Claude Code's and pi's built-in tools,
  /// checked in priority order so the chip shows the single most useful
  /// value (a path or command) rather than every argument.
  private static let toolArgKeys = [
    "file_path", "path", "command", "pattern", "query", "url", "description",
  ]

  private static func toolSummary(name: String?, args: [String: Any]?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    guard let args else { return name }
    for key in toolArgKeys {
      if let value = args[key] as? String, !value.isEmpty {
        return "\(name): \(truncate(value, 60))"
      }
    }
    return name
  }

  private static func truncate(_ s: String, _ limit: Int) -> String {
    s.count > limit ? String(s.prefix(limit)) + "…" : s
  }

  /// pi nests a run under `<timestamp>_<sessionId>/<hash>/run-N/session.jsonl`
  /// and can have multiple runs (resumes) — pick whichever `session.jsonl`
  /// was written to most recently. Most sessions are a flat
  /// `<timestamp>_<sessionId>.jsonl` file directly in the project
  /// directory; some (resumed/branched ones) are instead a
  /// `<timestamp>_<sessionId>` *directory* holding nested
  /// `<hash>/run-N/session.jsonl` files — confirmed both shapes exist side
  /// by side on this machine, so both must be handled.
  private static func latestPiSessionFile(under projectDir: URL, sessionId: String) -> URL? {
    let fm = FileManager.default
    guard
      let topLevel = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
    else { return nil }

    if let flatFile = topLevel.first(where: {
      $0.lastPathComponent.hasSuffix("_\(sessionId).jsonl")
    }) {
      return flatFile
    }

    guard
      let sessionDir = topLevel.first(where: { $0.lastPathComponent.hasSuffix("_\(sessionId)") }),
      let enumerator = fm.enumerator(
        at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }

    var best: (url: URL, date: Date)?
    for case let fileURL as URL in enumerator {
      guard fileURL.lastPathComponent == "session.jsonl" else { continue }
      let date =
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
        ?? .distantPast
      if best == nil || date > best!.date {
        best = (fileURL, date)
      }
    }
    return best?.url
  }

  // MARK: - shared

  private static func textBlocks(_ content: [[String: Any]]) -> String {
    content.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }.joined(separator: "\n")
  }

  private static func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Reads only the last `tailBytes` of `url` rather than loading a
  /// potentially large transcript fully into memory.
  private static func tailLines(of url: URL) -> [String]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }
}
