import Foundation

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
///
/// pi: `~/.pi/agent/sessions/<"-" + cwd.replacingOccurrences(of: "/", with: "-") + "--">/`,
/// then either a flat `<timestamp>_<sessionId>.jsonl` file directly in that
/// directory (the common case), or — for sessions that got resumed/branched —
/// a `<timestamp>_<sessionId>` *directory* holding nested
/// `<hash>/run-N/session.jsonl` files instead, in which case the most
/// recently modified one is used. Confirmed both shapes exist side by side on
/// this machine. Each line has `message.role`/`message.content` with block
/// types `text`/`thinking`/`toolCall`. Best-effort: pi's format is a
/// branching id/parentId tree (see https://pi.dev/docs/latest/session-format)
/// and this deliberately ignores branches, just reading file order.
enum TranscriptPreview {
    private static let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    private static let piSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions")

    /// Only reads the tail of the transcript, not the whole (potentially
    /// multi-MB, long-running-session) file.
    private static let tailBytes = 200_000

    static func preview(for session: AgentSession) -> String {
        guard let sessionId = session.sessionId, !sessionId.isEmpty else {
            return "(no session id in status file)"
        }
        let text: String?
        switch session.agentName {
        case "claude": text = claudePreview(sessionId: sessionId, cwd: session.panePath)
        case "pi": text = piPreview(sessionId: sessionId, cwd: session.panePath)
        default: text = nil
        }
        return text ?? "(preview unavailable)"
    }

    // MARK: - Claude Code

    private static func claudeEncode(_ path: String) -> String {
        String(
            path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    private static func claudePreview(sessionId: String, cwd: String) -> String? {
        let file =
            claudeProjectsDir
            .appendingPathComponent(claudeEncode(cwd))
            .appendingPathComponent("\(sessionId).jsonl")
        guard let lines = tailLines(of: file) else { return nil }

        for line in lines.reversed() {
            guard let obj = jsonObject(line),
                obj["type"] as? String == "assistant",
                let message = obj["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }

            let text = textBlocks(content)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - pi

    private static func piPreview(sessionId: String, cwd: String) -> String? {
        let encodedDir = "-" + cwd.replacingOccurrences(of: "/", with: "-") + "--"
        let projectDir = piSessionsDir.appendingPathComponent(encodedDir)
        guard let file = latestPiSessionFile(under: projectDir, sessionId: sessionId),
            let lines = tailLines(of: file)
        else { return nil }

        for line in lines.reversed() {
            guard let obj = jsonObject(line),
                obj["type"] as? String == "message",
                let message = obj["message"] as? [String: Any],
                message["role"] as? String == "assistant",
                let content = message["content"] as? [[String: Any]]
            else { continue }

            let text = textBlocks(content)
            if !text.isEmpty { return text }
        }
        return nil
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
        guard let topLevel = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
        else { return nil }

        if let flatFile = topLevel.first(where: { $0.lastPathComponent.hasSuffix("_\(sessionId).jsonl") }) {
            return flatFile
        }

        guard let sessionDir = topLevel.first(where: { $0.lastPathComponent.hasSuffix("_\(sessionId)") }),
            let enumerator = fm.enumerator(
                at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var best: (url: URL, date: Date)?
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "session.jsonl" else { continue }
            let date =
                (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
