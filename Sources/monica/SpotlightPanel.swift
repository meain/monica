import AppKit
import SwiftUI

/// Borderless window that can still become key (needed for the filter text
/// field to receive keystrokes). Same trick as beacon's `FloatingPanel`.
final class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// State + keyboard handling for the Spotlight-style picker. Uses an AppKit
/// local event monitor for arrow/return/escape because SwiftUI's
/// `.onKeyPress` doesn't reliably receive focus inside a borderless panel —
/// ported from beacon's `PickerModel`.
@MainActor
final class SpotlightModel: ObservableObject {
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

    private func filterChanged() {
        let count = filteredSessions.count
        guard count > 0 else { selection = 0; return }
        selection = min(selection, count - 1)
    }

    func commit() {
        let list = filteredSessions
        guard list.indices.contains(selection) else { cancel(); return }
        onCommit?(list[selection])
    }

    func cancel() {
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

private struct SpotlightView: View {
    @ObservedObject var model: SpotlightModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch to agent…", text: $model.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(12)
                .focused($focused)

            Divider()

            ScrollView {
                AgentListView(
                    sessions: model.filteredSessions,
                    selection: model.selection,
                    onSelect: { session in
                        if let idx = model.filteredSessions.firstIndex(of: session) {
                            model.selection = idx
                        }
                        model.commit()
                    }
                )
            }
            // A `maxHeight` alone reports zero ideal height to the hosting
            // window (ScrollView has no intrinsic content size) — same
            // "ScrollView collapses to zero height" gotcha noted in beacon's
            // AGENTS.md. Use a real fixed height instead.
            .frame(height: 320)
        }
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear { focused = true }
    }
}

/// Owns the floating panel lifecycle: show on hotkey, hide on commit/cancel/
/// resigning key, centered on the active screen (no position memory, unlike
/// beacon — this panel is meant to be summoned and dismissed quickly).
@MainActor
final class SpotlightController {
    private var panel: FloatingPanel?
    private let model = SpotlightModel()
    private let scanner: AgentScanner

    init(scanner: AgentScanner) {
        self.scanner = scanner
        model.onCommit = { [weak self] session in
            Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
            self?.dismiss()
        }
        model.onCancel = { [weak self] in self?.dismiss() }
    }

    func toggle() {
        if panel != nil { dismiss() } else { present() }
    }

    private func present() {
        let controller = NSHostingController(rootView: SpotlightView(model: model))
        let panel = FloatingPanel(contentViewController: controller)
        panel.styleMask = [.borderless, .fullSizeContentView]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel

        scanner.scan()
        model.activate(sessions: scanner.sessions)

        if let screen = NSScreen.main {
            let f = panel.frame
            panel.setFrameOrigin(
                NSPoint(x: screen.visibleFrame.midX - f.width / 2, y: screen.visibleFrame.midY - f.height / 2 + 100))
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(resign), name: NSWindow.didResignKeyNotification, object: panel)
    }

    @objc private func resign() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isKeyWindow == false else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        model.deactivate()
        panel?.orderOut(nil)
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        }
        panel = nil
    }
}
