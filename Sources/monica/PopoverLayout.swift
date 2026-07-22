import SwiftUI

/// Shared layout constants for the menu bar popover. Every section used to
/// tune its own padding independently, and those totals drifted out of sync
/// twice (8pt vs. 4+10=14pt for rows, then again when a new section was
/// added without matching it) — both caught only by screenshot, neither
/// caused a compiler warning or crash. Routing every section through this
/// instead of a local literal is what actually prevents that class of bug.
enum PopoverLayout {
  // 400 + 2*outerPadding, so the new card margins don't eat into text space
  // that fit comfortably in the old flush-edge layout (e.g. full project
  // names like "control-plane-ops-cli" used to fit without truncating).
  static let width: CGFloat = 416

  /// Margin between the popover's own edge and the outermost card — this is
  /// what gives the "floating cards" look its breathing room, as opposed to
  /// content running flush to the popover border.
  static let outerPadding: CGFloat = 8

  /// Vertical gap between adjacent cards, replacing the old `Divider()`
  /// lines — a card boundary reads as a group change on its own, so a hard
  /// rule between them stopped being necessary.
  static let cardSpacing: CGFloat = 6

  static let cornerRadius: CGFloat = 12
  static let innerCornerRadius: CGFloat = 7

  static let horizontalInset: CGFloat = 12

  /// Width actually available for wrapped text inside a card's content
  /// area: popover width, minus the outer card margin on both sides, minus
  /// each card's own inner horizontal padding on both sides.
  static let contentWidth: CGFloat = width - outerPadding * 2 - horizontalInset * 2

  /// Agent rows split `horizontalInset` into an outer part (between the
  /// card edge and the selection highlight, so the highlight doesn't touch
  /// the edge) and an inner part (between the highlight and the row text).
  /// They must sum to `horizontalInset` so row text stays aligned with
  /// every other section.
  static let rowInnerInset: CGFloat = 8
  static let rowOuterInset: CGFloat = horizontalInset - rowInnerInset
}

extension View {
  /// Fills the available width (so content doesn't shrink-to-fit and drift
  /// off the shared left margin — see `PopoverLayout`'s doc comment) and
  /// applies the standard section padding.
  func popoverSection(vertical: CGFloat = 10) -> some View {
    self
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, PopoverLayout.horizontalInset)
      .padding(.vertical, vertical)
  }

  /// Wraps a section in the shared "floating card" look: a subtle fill plus
  /// a hairline stroke so sections read as distinct groups against the
  /// popover's material background — replaces the flat `Divider()`-only
  /// separation the popover used before. Pass `tint` to make a section
  /// (e.g. compose mode) visually stand out as a different state.
  func popoverCard(tint: Color? = nil) -> some View {
    self
      .background(
        RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius)
          .fill(tint?.opacity(0.12) ?? Color(nsColor: .quaternarySystemFill))
      )
      .overlay(
        RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius)
          .stroke(tint?.opacity(0.35) ?? Color.primary.opacity(0.07), lineWidth: 1)
      )
  }
}
