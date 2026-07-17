import SwiftUI

/// Renders agent transcript text (Claude Code/pi assistant messages are
/// usually markdown) with inline markdown formatting — bold, italic, inline
/// code, links.
///
/// One `Text(AttributedString)` for the *whole* document does not work:
/// `Text` only honors per-character formatting attributes from the parsed
/// `AttributedString`, not block-level structure like paragraph/heading
/// breaks (SwiftUI ignores `presentationIntent`) — every line/section runs
/// together with no separator at all (confirmed visually: "GreenHighlights
/// CurrentStatusHitesh" from source that had those as separate
/// lines/headings). Splitting the raw text into lines first and rendering
/// each as its own `Text` in a `VStack` is what actually preserves the
/// breaks, at the cost of not handling multi-line wrapped paragraphs as one
/// flowing block — an acceptable tradeoff for a small preview panel, not the
/// main content surface. Fenced code blocks also don't get syntax
/// highlighting this way (unlike beacon's full custom `MarkdownParser`/
/// `MarkdownView`/`SyntaxHighlighter`), just plain text per line.
struct MarkdownPreviewText: View {
    let raw: String

    private var lines: [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(inlineAttributed(line))
            }
        }
    }

    private func inlineAttributed(_ line: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
    }
}
