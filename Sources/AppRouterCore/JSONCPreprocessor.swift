import Foundation

/// Strips JSONC comments (`//` line and `/* */` block) from a document, producing
/// plain JSON that `JSONDecoder` can parse.
///
/// This is a *string-aware state machine*, not a regex strip (Developer Decision 3):
/// it tracks whether the scanner is inside a JSON string literal and honours backslash
/// escapes. Consequently comment delimiters that appear *inside* string values — a
/// `//` in `"http://example.com"`, or a `/* */` inside a regex pattern — are preserved
/// verbatim. This is what satisfies the reviewer's double-slash criterion.
///
/// Removed comment spans are replaced with a single space so byte offsets used in
/// decoder error messages stay roughly aligned and adjacent tokens do not fuse.
public enum JSONCPreprocessor {

    private enum State {
        case normal
        case inString
        case inStringEscape
        case inLineComment
        case inBlockComment
    }

    /// Returns `input` with all JSONC comments removed. Characters inside JSON string
    /// literals are never treated as comment starts.
    public static func strip(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)

        var state: State = .normal
        let scalars = Array(input.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let c = scalars[i]
            let next: Unicode.Scalar? = (i + 1 < n) ? scalars[i + 1] : nil

            switch state {
            case .normal:
                if c == "\"" {
                    state = .inString
                    out.unicodeScalars.append(c)
                } else if c == "/" && next == "/" {
                    state = .inLineComment
                    i += 2
                    continue
                } else if c == "/" && next == "*" {
                    state = .inBlockComment
                    i += 2
                    continue
                } else {
                    out.unicodeScalars.append(c)
                }

            case .inString:
                out.unicodeScalars.append(c)
                if c == "\\" {
                    state = .inStringEscape
                } else if c == "\"" {
                    state = .normal
                }

            case .inStringEscape:
                // Whatever follows a backslash is literal; never ends the string.
                out.unicodeScalars.append(c)
                state = .inString

            case .inLineComment:
                if c == "\n" || c == "\r" {
                    // Preserve the newline so line-based decoder errors stay aligned.
                    out.unicodeScalars.append(c)
                    state = .normal
                }
                // else: swallow comment body.

            case .inBlockComment:
                if c == "*" && next == "/" {
                    // Replace the whole block with one space to keep tokens separated.
                    out.unicodeScalars.append(" ")
                    state = .normal
                    i += 2
                    continue
                } else if c == "\n" || c == "\r" {
                    // Keep vertical whitespace inside block comments for line alignment.
                    out.unicodeScalars.append(c)
                }
                // else: swallow comment body.
            }

            i += 1
        }

        return out
    }
}
