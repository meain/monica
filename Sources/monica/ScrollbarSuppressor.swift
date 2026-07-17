import AppKit
import SwiftUI

/// Reaches into the `NSScrollView` backing a SwiftUI `ScrollView` and forces
/// it to stop drawing/reserving space for a scroller, regardless of the
/// user's system-wide "Show scroll bars" preference.
///
/// `.scrollIndicators(.hidden)` alone does **not** do this: it only controls
/// SwiftUI's newer overlay-indicator API. When the system preference is
/// non-overlay (`Always`/`WhenScrolling` in
/// `defaults read NSGlobalDomain AppleShowScrollBars`, or even under
/// `Automatic` once content actually overflows), the classic AppKit
/// `NSScroller` still gets attached to the underlying `NSScrollView` and
/// keeps drawing a thumb — confirmed via a real screenshot showing a gray
/// scrollbar thumb in the "Last message" preview panel despite
/// `.scrollIndicators(.hidden)` being applied there. That legacy scroller is
/// also what reserves layout width inside the scroll view and shifts content
/// when it appears/disappears (the original bug this whole area is trying to
/// avoid — see `PopoverLayout`/`AgentListSection`'s doc comments).
///
/// Embed this as a `.background(ScrollbarSuppressor())` on the *content*
/// inside a `ScrollView` (not on the `ScrollView` itself) so its `NSView`
/// lands inside the scroll view's document view and `superview` walking
/// reaches the real `NSScrollView`. Directly setting `hasVerticalScroller`/
/// `hasHorizontalScroller` to `false` on that instance is authoritative —
/// it's the actual AppKit state SwiftUI's modifier doesn't fully control.
struct ScrollbarSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { configure(from: view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { configure(from: nsView) }
  }

  private func configure(from view: NSView) {
    guard let scrollView = enclosingScrollView(of: view) else { return }
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
  }

  private func enclosingScrollView(of view: NSView) -> NSScrollView? {
    var current = view.superview
    while let candidate = current {
      if let scrollView = candidate as? NSScrollView { return scrollView }
      current = candidate.superview
    }
    return nil
  }
}
