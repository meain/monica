import AppKit
import SwiftUI

/// A thin always-on-top strip docked to the top edge, showing one glyph per
/// agent at a glance. Click a glyph to switch to it. Position is fixed for
/// v1 — see DESIGN.md's "future work" for a draggable/configurable version.
struct HUDContentView: View {
    @ObservedObject var scanner: AgentScanner
    let onSelect: (AgentSession) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if scanner.sessions.isEmpty {
                Text("○")
                    .foregroundColor(.secondary)
            } else {
                ForEach(scanner.sessions) { session in
                    Text(session.status.glyph)
                        .foregroundColor(
                            session.status == .working
                                ? .green : session.status == .waiting ? .yellow : .secondary
                        )
                        .help("\(session.displayTitle) — \(session.status.rawValue)")
                        .onTapGesture { onSelect(session) }
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

@MainActor
final class HUDPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDContentView>?
    private var resizeTimer: Timer?
    private let scanner: AgentScanner

    init(scanner: AgentScanner) {
        self.scanner = scanner
    }

    func show() {
        guard panel == nil else { return }

        let content = HUDContentView(scanner: scanner) { session in
            Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
        }
        // NSHostingController doesn't reliably auto-size a borderless NSPanel
        // (its `.standardBounds` sizing option is a no-op here). NSHostingView
        // computes a real `fittingSize` off the SwiftUI layout independent of
        // any window, so use that to size the panel explicitly instead.
        let hostingView = NSHostingView(rootView: content)
        self.hostingView = hostingView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        self.panel = panel

        fitAndReposition()
        panel.orderFrontRegardless()

        // Re-fit periodically since the glyph count (and so the ideal size)
        // changes as agents come and go between scans.
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fitAndReposition() }
        }
    }

    func hide() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    /// Top edge, centered, just under the menu bar.
    private func fitAndReposition() {
        guard let panel, let hostingView, let screen = NSScreen.main else { return }
        let fitting = hostingView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let x = screen.visibleFrame.midX - fitting.width / 2
        let y = screen.visibleFrame.maxY - fitting.height - 4
        panel.setFrame(NSRect(x: x, y: y, width: fitting.width, height: fitting.height), display: true)
    }
}
