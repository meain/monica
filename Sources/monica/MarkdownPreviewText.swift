import SwiftUI

/// Renders agent transcript text (Claude Code/pi assistant messages are
/// usually markdown) as SwiftUI-native `AttributedString` markdown — bold,
/// italic, inline code, links, and paragraph/list/heading structure.
///
/// Deliberately not a full custom renderer (unlike beacon's
/// `MarkdownParser`/`MarkdownView`/`SyntaxHighlighter`): fenced code blocks
/// won't get syntax highlighting, just plain text, since `AttributedString`'s
/// built-in parser doesn't handle those specially. That's an acceptable
/// tradeoff for a small preview panel, not the main content surface.
struct MarkdownPreviewText: View {
    let raw: String

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    var body: some View {
        Text(attributed)
    }
}
