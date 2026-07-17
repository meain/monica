import Carbon.HIToolbox
import Foundation

/// Renders a Carbon keyCode + modifier bitmask as a human-readable shortcut
/// label, e.g. "⌃⌥⇧A". Only covers the keys realistically used for a
/// launcher-style hotkey (letters, digits, a handful of named keys) — good
/// enough for a settings display, not a general keycode decoder.
enum HotKeyFormatter {
    private static let keyLabels: [UInt32: String] = {
        var labels: [UInt32: String] = [:]
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let letterCodes: [UInt32] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        ]
        for (letter, code) in zip(letters, letterCodes) {
            labels[code] = String(letter)
        }
        let digitLabels = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        let digitCodes: [UInt32] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (label, code) in zip(digitLabels, digitCodes) {
            labels[code] = label
        }
        labels[UInt32(kVK_Space)] = "Space"
        labels[UInt32(kVK_Return)] = "Return"
        labels[UInt32(kVK_Tab)] = "Tab"
        labels[UInt32(kVK_Escape)] = "Escape"
        labels[UInt32(kVK_LeftArrow)] = "\u{2190}"
        labels[UInt32(kVK_RightArrow)] = "\u{2192}"
        labels[UInt32(kVK_UpArrow)] = "\u{2191}"
        labels[UInt32(kVK_DownArrow)] = "\u{2193}"
        return labels
    }()

    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        // Standard macOS modifier glyph order.
        if modifiers & UInt32(controlKey) != 0 { result += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { result += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { result += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { result += "\u{2318}" }
        result += keyLabels[keyCode] ?? "?"
        return result
    }
}
