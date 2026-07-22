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
///
/// Reapplying only from `makeNSView`/`updateNSView` (i.e. SwiftUI's own
/// update cycle), or even from `layout()`, is not enough: a real mouse
/// hovering over or scrolling the view makes AppKit reveal the classic
/// scroller *internally* without necessarily invalidating this subview's own
/// layout — confirmed by the fact that a programmatic/offscreen render
/// (`MONICA_SHOT`, no real HID input) never reproduces the stuck scrollbar,
/// but a real mouse-driven session on this machine does every time
/// (`AppleShowScrollBars: Automatic` reveals a classic, space-reserving
/// scroller once a physical mouse hovers/scrolls, and that reveal isn't
/// tied to any SwiftUI state change or guaranteed layout pass on this
/// particular subview). `SuppressorView` instead polls on a short repeating
/// timer while it's in a window and re-asserts the override every tick —
/// brute-force, but the one thing that reliably wins the race against
/// AppKit's internal reveal regardless of what triggers it.
struct ScrollbarSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    SuppressorView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class SuppressorView: NSView {
    private var timer: Timer?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      timer?.invalidate()
      timer = nil
      guard window != nil else { return }
      configure(from: self)
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self else { return }
        configure(from: self)
      }
    }

    deinit {
      timer?.invalidate()
    }
  }
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
