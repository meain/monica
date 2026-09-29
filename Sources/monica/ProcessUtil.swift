import Foundation

/// Runs a process to completion and returns its stdout, or `nil` if it
/// couldn't be launched or didn't exit within `timeout` (it's terminated in
/// that case). A non-zero exit still returns whatever stdout it produced —
/// e.g. `tmux list-panes` with no server running returns "" rather than nil,
/// which callers treat as a real "no panes" answer, whereas nil means "no
/// answer at all" and callers keep their previous data instead.
///
/// The timeout exists because every scan used to block on `waitUntilExit()`
/// with no limit — a wedged tmux server would hang the scanner forever.
func runCaptureChecked(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 3)
  -> String?
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  let exited = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in exited.signal() }
  do {
    try process.run()
  } catch {
    return nil
  }
  // Drain the pipe concurrently — a child that fills the pipe buffer blocks
  // until someone reads, so waiting for exit first could deadlock.
  var data = Data()
  let reader = DispatchGroup()
  DispatchQueue.global(qos: .userInitiated).async(group: reader) {
    data = pipe.fileHandleForReading.readDataToEndOfFile()
  }
  if exited.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    return nil
  }
  reader.wait()
  return String(data: data, encoding: .utf8) ?? ""
}

/// `runCaptureChecked`, collapsing "no answer" to "". Never throws — callers
/// must degrade gracefully (empty tmux server, missing binaries, etc).
func runCapture(_ launchPath: String, _ arguments: [String]) -> String {
  runCaptureChecked(launchPath, arguments) ?? ""
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

  /// `run`, but nil on launch failure/timeout — see `runCaptureChecked`.
  static func runChecked(_ args: [String]) -> String? {
    runCaptureChecked(path, arguments(args))
  }
}
