import AppKit
import SwiftUI

/// `NSStatusItem` + `NSPopover`, templated on mactraffic's `StatusBarController`.
/// The status item's title is the aggregate glyph (highest-priority status
/// across all sessions) + a count; clicking it opens a popover with the full
/// list.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let scanner: AgentScanner
    private var observer: NSObjectProtocol?

    init(scanner: AgentScanner) {
        self.scanner = scanner
        self.statusItem = NSStatusBar.system.statusItem(withLength: 44)
        self.popover = NSPopover()
        popover.behavior = .transient

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        rebuildContent()
        updateTitle()

        // AgentScanner is @MainActor + @Published, but there's no Combine
        // import here — poll the title on the same cadence instead of
        // subscribing, keeping this controller dependency-free.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let sessions = scanner.sessions
        let aggregate = sessions.map(\.status).max() ?? .idle
        let glyph = sessions.isEmpty ? "○" : aggregate.glyph
        let title = sessions.isEmpty ? glyph : "\(glyph) \(sessions.count)"
        let color: NSColor =
            sessions.isEmpty
            ? .secondaryLabelColor
            : (aggregate == .working ? .systemGreen : aggregate == .waiting ? .systemYellow : .secondaryLabelColor)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
            ]
        )
        rebuildContent()
    }

    private func rebuildContent() {
        let content = AgentListView(sessions: scanner.sessions) { [weak self] session in
            Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
            self?.popover.performClose(nil)
        }
        .frame(width: 280)
        popover.contentViewController = NSHostingController(rootView: content)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            rebuildContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
