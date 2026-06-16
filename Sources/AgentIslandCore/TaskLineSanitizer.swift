import Foundation

/// Agent output is untrusted. This produces a safe, glanceable task line: ANSI escape
/// sequences and control characters stripped, whitespace collapsed, truncated to ~40 chars.
public enum TaskLineSanitizer {
    // Pattern begins with a literal ESC (U+001B) followed by an ICU bracket expression
    // matching a CSI sequence: ESC [ <params> <intermediates> <final>.
    private static let ansiRegex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    public static func sanitize(_ raw: String, maxLength: Int = 40) -> String {
        let fullRange = NSRange(raw.startIndex..., in: raw)
        let noAnsi = ansiRegex.stringByReplacingMatches(
            in: raw, range: fullRange, withTemplate: "")

        // Drop non-whitespace control characters (keep tab/newline/CR so the
        // whitespace-collapse step below can normalize them to single spaces).
        let noControl = String(noAnsi.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isWhitespaceControl = (v == 0x09 || v == 0x0A || v == 0x0D)
            let isOtherControl = (v < 0x20 && !isWhitespaceControl) || v == 0x7F
            return !isOtherControl
        })

        let collapsed = noControl
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > maxLength, maxLength > 0 else { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: maxLength - 1)
        return String(collapsed[collapsed.startIndex..<cut]) + "…"
    }
}
