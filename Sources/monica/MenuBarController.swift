import AppKit
import SwiftUI

private struct FooterRow: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarPopoverView: View {
    @ObservedObject var model: AgentPickerModel
    let onSettings: () -> Void
    let onQuit: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.composeTarget {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message \(target.displayTitle)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Type and press Return to send…", text: $model.composeText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                }
                .padding(8)
            } else {
                TextField("Search agents…", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(8)
                    .focused($searchFocused)
            }

            Divider()

            ScrollView {
                AgentListView(
                    sessions: model.filteredSessions,
                    selection: model.selection,
                    onSelect: model.choose
                )
            }
            // A `maxHeight` alone reports zero ideal height to the hosting
            // popover — same ScrollView gotcha noted in AGENTS.md. Use a real
            // fixed height instead.
            .frame(height: 150)

            if model.composeTarget == nil {
                Text("↩ switch  ·  ⌘↩ send message")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Last message")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(model.previewText.isEmpty ? "No active AI agents" : model.previewText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            // `ScrollView` doesn't reliably constrain a
                            // `Text`'s wrapping width from `maxWidth:
                            // .infinity` alone — it can propose an unbounded
                            // width, so the text stays on one line and blows
                            // out the popover's overall width. A genuine
                            // fixed width forces real wrapping.
                            .frame(width: 304, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 90)
                }
                .padding(8)
            }

            Divider()

            VStack(spacing: 0) {
                FooterRow(systemImage: "gearshape", title: "Settings…", action: onSettings)
                FooterRow(systemImage: "power", title: "Quit monica", action: onQuit)
            }
        }
        .frame(width: 320)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
    }
}

/// `NSStatusItem` + `NSPopover`, templated on mactraffic's `StatusBarController`.
/// The status item's title is the aggregate glyph (highest-priority status
/// across all sessions) + a count; the popover (opened either by clicking the
/// item or via the global hotkey — see `HotKeyManager`) holds search, the
/// full agent list, and Settings/Quit.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let scanner: AgentScanner
    private let model = AgentPickerModel()
    private var titleTimer: Timer?

    init(scanner: AgentScanner, onOpenSettings: @escaping () -> Void) {
        self.scanner = scanner
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        popover.behavior = .transient
        // Explicit size, matching mactraffic's `StatusBarController`. Without
        // this, NSPopover has to guess a size from the hosted SwiftUI view
        // before its first layout pass — that ambiguous guess is what caused
        // the popover to anchor ~180pt below the status item instead of
        // right beneath it (see AGENTS.md).
        popover.contentSize = NSSize(width: 320, height: 400)

        model.onCommit = { [weak self] session in
            Switcher.activate(session, targetApp: AppSettings.shared.targetApp)
            self?.closePopover()
        }
        model.onSendMessage = { [weak self] session, text in
            Switcher.sendMessage(session, text: text)
            self?.closePopover()
        }
        model.onCancel = { [weak self] in self?.closePopover() }

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
        }

        let content = MenuBarPopoverView(
            model: model,
            onSettings: { [weak self] in
                self?.closePopover()
                onOpenSettings()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: content)

        updateTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    @objc private func handleClick(_ sender: AnyObject?) {
        togglePopover()
    }

    /// Called both from the status item click and from the global hotkey —
    /// there's deliberately only one picker UI now, not a separate Spotlight
    /// window.
    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        scanner.scan()
        model.activate(sessions: scanner.sessions)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // `.onAppear`'s `searchFocused = true` races the window actually
        // becoming key — that assignment can get silently dropped if it
        // lands before `makeKey()` has taken effect. Retry once the run
        // loop has caught up, after re-confirming key status.
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
            self?.model.requestFocus()
        }
    }

    private func closePopover() {
        model.deactivate()
        popover.performClose(nil)
    }

    /// One glyph per agent, colored by status — the same "at a glance" display
    /// the old always-on HUD strip gave, now living directly in the menu bar
    /// title instead of a separate floating window.
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let sessions = scanner.sessions
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let title = NSMutableAttributedString()

        if sessions.isEmpty {
            title.append(
                NSAttributedString(
                    string: "○", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            for (index, session) in sessions.enumerated() {
                if index > 0 {
                    title.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                let color: NSColor =
                    session.status == .working
                    ? .systemGreen : session.status == .waiting ? .systemYellow : .secondaryLabelColor
                title.append(
                    NSAttributedString(
                        string: session.status.glyph, attributes: [.font: font, .foregroundColor: color]))
            }
        }

        button.attributedTitle = title
        if popover.isShown {
            model.sessions = sessions
        }
    }
}
