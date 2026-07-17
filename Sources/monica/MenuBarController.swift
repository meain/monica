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
            .padding(.horizontal, 12)
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

    /// Applied consistently to the search/compose field, the preview panel,
    /// and (via `AgentRowView`) the list rows, so text in every section lines
    /// up along the same left margin — they'd previously accumulated
    /// different total insets (8pt here vs. 4+10=14pt for rows), which is
    /// what "the padding is wrong" turned out to mean (confirmed via
    /// screenshot).
    private let horizontalInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 8)
            } else {
                TextField("Search agents…", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 8)
                    .focused($searchFocused)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    AgentListView(
                        sessions: model.filteredSessions,
                        selection: model.selection,
                        onSelect: model.choose
                    )
                }
                // A `maxHeight` alone reports zero ideal height to the hosting
                // popover — same ScrollView gotcha noted in AGENTS.md. Use a
                // real height instead — `MenuBarController` computes this
                // from the screen size (up to 60% of it) each time the
                // popover opens, rather than a small fixed value.
                .frame(height: model.listHeight)
                .onChange(of: model.selection) { scrollToSelection(proxy) }
            }

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
                        MarkdownPreviewText(
                            raw: model.previewText.isEmpty ? "No active AI agents" : model.previewText
                        )
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        // `ScrollView` doesn't reliably constrain a
                        // `Text`'s wrapping width from `maxWidth: .infinity`
                        // alone — it can propose an unbounded width, so the
                        // text stays on one line and blows out the
                        // popover's overall width. A genuine fixed width
                        // forces real wrapping. 400 (popover width) minus
                        // horizontalInset on both sides.
                        .frame(width: 400 - horizontalInset * 2, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(height: 90)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 8)
            }

            Divider()

            VStack(spacing: 0) {
                FooterRow(systemImage: "gearshape", title: "Settings…", action: onSettings)
                FooterRow(systemImage: "power", title: "Quit Monica", action: onQuit)
            }
        }
        .frame(width: 400)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let list = model.filteredSessions
        guard list.indices.contains(model.selection) else { return }
        withAnimation { proxy.scrollTo(list[model.selection].id, anchor: .center) }
    }
}

/// `NSStatusItem` + `NSPopover`, templated on mactraffic's `StatusBarController`.
/// The status item's title shows one glyph per agent; the popover (opened
/// either by clicking the item or via the global hotkey — see
/// `HotKeyManager`) holds search, the full agent list, a message preview,
/// and Settings/Quit.
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
        popover.contentSize = NSSize(width: 400, height: 300)

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
        resizeForScreen()
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

    /// Sizes the list to how many agents are actually showing, not always to
    /// the maximum — only clamped by 60% of the active screen's height for
    /// when there are a lot of them. `fixedChrome` is a rough estimate of
    /// everything in the popover besides the scrollable list (search field,
    /// hint row, preview panel, footer, dividers) — `NSPopover.contentSize`
    /// is itself just a hint (see AGENTS.md), so this doesn't need to be
    /// exact.
    private func resizeForScreen() {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let fixedChrome: CGFloat = 240
        let maxListHeight = max(agentRowHeight, screenHeight * 0.6 - fixedChrome)
        let rowCount = max(model.filteredSessions.count, 1)
        let desiredListHeight = CGFloat(rowCount) * agentRowHeight + 8
        let listHeight = min(desiredListHeight, maxListHeight)
        model.listHeight = listHeight
        popover.contentSize = NSSize(width: 400, height: fixedChrome + listHeight)
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
                    session.isStale
                    ? .secondaryLabelColor
                    : (session.status == .working
                        ? .systemGreen : session.status == .waiting ? .systemYellow : .secondaryLabelColor)
                title.append(
                    NSAttributedString(
                        string: session.displayGlyph, attributes: [.font: font, .foregroundColor: color]))
            }
        }

        button.attributedTitle = title
        if popover.isShown {
            model.sessions = sessions
        }
    }
}
