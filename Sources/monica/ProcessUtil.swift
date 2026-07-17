import Foundation

/// Runs a process to completion and returns its stdout, trimmed. Never throws —
/// callers must degrade gracefully (empty tmux server, missing binaries, etc).
func runCapture(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Fires a process without waiting for or capturing output.
func runFireAndForget(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// GUI apps launched by launchd get a minimal PATH that doesn't include
/// `~/.nix-profile/bin`, where tmux actually lives on this machine. Resolve it
/// once via a login shell (same fix beacon needed for missing API keys), so
/// every tmux invocation in the app goes through `TmuxCLI.run`.
enum TmuxCLI {
    static let path: String = {
        let resolved = runCapture("/bin/zsh", ["-lc", "command -v tmux"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? "/usr/bin/env" : resolved
    }()

    private static func arguments(_ args: [String]) -> [String] {
        path == "/usr/bin/env" ? ["tmux"] + args : args
    }

    @discardableResult
    static func run(_ args: [String]) -> String {
        runCapture(path, arguments(args))
    }
}
