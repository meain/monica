import SwiftUI

/// Shared layout constants for the menu bar popover. Every section used to
/// tune its own padding independently, and those totals drifted out of sync
/// twice (8pt vs. 4+10=14pt for rows, then again when a new section was
/// added without matching it) — both caught only by screenshot, neither
/// caused a compiler warning or crash. Routing every section through this
/// instead of a local literal is what actually prevents that class of bug.
enum PopoverLayout {
  static let width: CGFloat = 400
  static let horizontalInset: CGFloat = 12
  static let contentWidth: CGFloat = width - horizontalInset * 2

  /// Agent rows split `horizontalInset` into an outer part (between the
  /// popover edge and the selection highlight, so the highlight doesn't
  /// touch the edge) and an inner part (between the highlight and the row
  /// text). They must sum to `horizontalInset` so row text stays aligned
  /// with every other section.
  static let rowInnerInset: CGFloat = 8
  static let rowOuterInset: CGFloat = horizontalInset - rowInnerInset
}

extension View {
  /// Fills the available width (so content doesn't shrink-to-fit and drift
  /// off the shared left margin — see `PopoverLayout`'s doc comment) and
  /// applies the standard section padding.
  func popoverSection(vertical: CGFloat = 8) -> some View {
    self
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, PopoverLayout.horizontalInset)
      .padding(.vertical, vertical)
  }
}
