import AppKit
import Foundation

/// Search + keyboard-navigation state for the menu bar popover's agent list.
/// Uses an AppKit local event monitor for arrow/return/escape because
/// SwiftUI's `.onKeyPress` doesn't reliably receive focus inside a popover's
/// text field — same reasoning as beacon's `PickerModel`.
@MainActor
final class AgentPickerModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var selection = 0
    @Published var filterText: String = "" {
        didSet { filterChanged() }
    }

    var filteredSessions: [AgentSession] {
        guard !filterText.isEmpty else { return sessions }
        return sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(filterText)
                || $0.displaySubtitle.localizedCaseInsensitiveContains(filterText)
        }
    }

    var onCommit: ((AgentSession) -> Void)?
    var onCancel: (() -> Void)?

    nonisolated(unsafe) private var monitor: Any?

    func activate(sessions: [AgentSession]) {
        self.sessions = sessions
        selection = 0
        filterText = ""
        installMonitor()
    }

    func deactivate() {
        removeMonitor()
    }

    func move(_ delta: Int) {
        let list = filteredSessions
        guard !list.isEmpty else { return }
        selection = min(max(0, selection + delta), list.count - 1)
    }

    func choose(_ session: AgentSession) {
        if let idx = filteredSessions.firstIndex(of: session) {
            selection = idx
        }
        commit()
    }

    private func filterChanged() {
        let count = filteredSessions.count
        guard count > 0 else { selection = 0; return }
        selection = min(selection, count - 1)
    }

    private func commit() {
        let list = filteredSessions
        guard list.indices.contains(selection) else { cancel(); return }
        onCommit?(list[selection])
    }

    private func cancel() {
        onCancel?()
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 126: self.move(-1); return nil  // up
            case 125: self.move(1); return nil  // down
            case 36, 76: self.commit(); return nil  // return / enter
            case 53: self.cancel(); return nil  // escape
            default: return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
