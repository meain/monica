import SwiftUI

/// The menu bar popover's SwiftUI content, decomposed into one section per
/// row of the layout diagram in DESIGN.md. `MenuBarController` owns the
/// `NSPopover`/`NSStatusItem` mechanics; this file owns everything visual.
struct MenuBarPopoverView: View {
    @ObservedObject var model: AgentPickerModel
    let onSettings: () -> Void
    let onQuit: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.composeTarget != nil {
                ComposeFieldSection(model: model, isFocused: $searchFocused)
            } else {
                SearchFieldSection(model: model, isFocused: $searchFocused)
            }

            Divider()

            AgentListSection(model: model)

            if model.composeTarget == nil {
                Divider()
                LastMessageSection(text: model.previewText)
            }

            Divider()

            FooterSection(onSettings: onSettings, onQuit: onQuit)
        }
        .frame(width: PopoverLayout.width)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
    }
}

private struct SearchFieldSection: View {
    @ObservedObject var model: AgentPickerModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField("Search agents…", text: $model.filterText)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused(isFocused)
            .popoverSection()
    }
}

private struct ComposeFieldSection: View {
    @ObservedObject var model: AgentPickerModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let target = model.composeTarget {
                Text("Message \(target.displayTitle)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            TextField("Type and press Return to send…", text: $model.composeText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(isFocused)
        }
        .popoverSection()
    }
}

private struct AgentListSection: View {
    @ObservedObject var model: AgentPickerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                AgentListView(
                    sessions: model.filteredSessions,
                    selection: model.selection,
                    onSelect: model.choose
                )
                // See `ScrollbarSuppressor`'s doc comment: `.scrollIndicators
                // (.hidden)` below doesn't override AppKit's classic
                // `NSScroller`, which still draws (and reserves width) once
                // content actually overflows under a non-overlay system
                // scrollbar setting. This reaches the real `NSScrollView`
                // backing this `ScrollView` and disables its scroller
                // directly, which is the authoritative setting.
                .background(ScrollbarSuppressor())
            }
            // A `maxHeight` alone reports zero ideal height to the hosting
            // popover — same ScrollView gotcha noted in AGENTS.md. Use a
            // real height instead — `MenuBarController` computes this from
            // the screen size (up to 60% of it) each time the popover
            // opens, rather than a small fixed value.
            .frame(height: model.listHeight)
            // A non-overlay scrollbar (depends on the user's system-wide
            // "Show scroll bars" setting) reserves width inside the
            // ScrollView, shrinking the content area and shifting things
            // when it appears/disappears. Hidden here since the list is
            // still fully scrollable via trackpad/arrow keys without it.
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { scrollToSelection(proxy) }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let list = model.filteredSessions
        guard list.indices.contains(model.selection) else { return }
        withAnimation { proxy.scrollTo(list[model.selection].id, anchor: .center) }
    }
}

private struct LastMessageSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last message")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            ScrollView {
                MarkdownPreviewText(raw: text.isEmpty ? "No active AI agents" : text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    // `ScrollView` doesn't reliably constrain a `Text`'s
                    // wrapping width from `maxWidth: .infinity` alone — it
                    // can propose an unbounded width, so the text stays on
                    // one line and blows out the popover's overall width. A
                    // genuine fixed width forces real wrapping.
                    .frame(width: PopoverLayout.contentWidth, alignment: .leading)
                    .textSelection(.enabled)
                    // This is the panel where the scrollbar thumb was
                    // actually confirmed visible via a real screenshot
                    // despite `.scrollIndicators(.hidden)` below — see
                    // `ScrollbarSuppressor`'s doc comment for why.
                    .background(ScrollbarSuppressor())
            }
            .frame(height: 90)
            .scrollIndicators(.hidden)
        }
        .popoverSection()
    }
}

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
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FooterSection: View {
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FooterRow(systemImage: "gearshape", title: "Settings…", action: onSettings)
            FooterRow(systemImage: "power", title: "Quit Monica", action: onQuit)
        }
    }
}
