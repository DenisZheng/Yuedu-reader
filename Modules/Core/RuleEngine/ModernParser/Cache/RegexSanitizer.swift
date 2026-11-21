import Foundation

/// 显式的 Java 正则近似转换。生产编译必须走 compile，不能先转换平台已支持的语法。
///
/// Book source authors write regex on Android, targeting Java's `java.util.regex` engine.
/// NSRegularExpression uses ICU, which differs in:
///  - Possessive quantifiers  `X++`, `X*+`, `X?+`, `X{n,m}+` — not in ICU, silently break compile
///  - Atomic groups           `(?>X)` — not in ICU, breaks compile
///  - `\R`                    — any Unicode line break; ICU does NOT support \R
///  - `\e`                    — ESC char; ICU needs `\x1B`
///  - Java flag `(?d)`        — UNIX_LINES mode; no ICU equivalent
///  - `\p{javaXxx}`           — Java-only Unicode category names
///
/// All conversions are semantically approximate.  Possessive quantifiers and
/// atomic groups lose their backtrack-preventing semantics but remain valid.
enum RegexSanitizer {

    // MARK: - Public API

    /// Sanitize a Java regex pattern for use with NSRegularExpression (ICU).
    /// Returns the original string unchanged if no Java-specific syntax is detected.
    static func sanitize(_ pattern: String) -> String {
        guard needsSanitization(pattern) else { return pattern }
        var s = pattern
        s = removePossessiveQuantifiers(s)
        s = s.replacingOccurrences(of: "(?>", with: "(?:")           // atomic group → non-capturing
        s = s.replacingOccurrences(of: "\\R", with: "(?:\\r\\n|[\\n\\r\\u0085\\u2028\\u2029])")
        s = s.replacingOccurrences(of: "\\e", with: "\\x1B")         // ESC char
        s = s.replacingOccurrences(of: "(?d)", with: "")             // UNIX_LINES flag
        s = convertJavaUnicodeCategories(s)
        return s
    }

    /// 优先保留平台支持的原语义；仅在原表达式无法编译时使用显式的近似转换。
    static func compile(_ pattern: String, options: NSRegularExpression.Options = []) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: options) }
        catch {
            let converted = sanitize(pattern)
            guard converted != pattern else { throw error }
            return try NSRegularExpression(pattern: converted, options: options)
        }
    }

    static func canCompile(_ pattern: String) -> Bool {
        (try? compile(pattern)) != nil
    }

    // MARK: - Private Helpers

    /// Quick scan: skip allocation of the regex pipeline when there is nothing to fix.
    private static func needsSanitization(_ pattern: String) -> Bool {
        pattern.contains("(?>")
        || pattern.contains("\\R")
        || pattern.contains("\\e")
        || pattern.contains("(?d)")
        || pattern.contains("\\p{java")
        || hasPossessiveQuantifier(pattern)
    }

    /// Detect `+`, `*`, `?`, `}` immediately followed by `+` (possessive).
    private static func hasPossessiveQuantifier(_ s: String) -> Bool {
        var prev: Character = "\0"
        for ch in s {
            if ch == "+" && (prev == "+" || prev == "*" || prev == "?" || prev == "}") {
                return true
            }
            prev = ch
        }
        return false
    }

    /// Strip the trailing `+` from possessive quantifiers:
    ///   `++` → `+`, `*+` → `*`, `?+` → `?`, `{n,m}+` → `{n,m}`
    /// Uses NSRegularExpression with a pattern that itself is ICU-safe.
    private static func removePossessiveQuantifiers(_ s: String) -> String {
        // Match a quantifier character (*+?}) followed immediately by + that is NOT itself
        // the start of a look-ahead / group (preceded by a quantifier, not `(`)
        guard let regex = try? NSRegularExpression(pattern: #"([*+?}])\+"#) else {
            return s
        }
        let ns = s as NSString
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1"
        )
    }

    /// Convert Java-only `\p{javaXxx}` Unicode category names to ICU equivalents.
    private static func convertJavaUnicodeCategories(_ s: String) -> String {
        var r = s
        let replacements: [(String, String)] = [
            ("\\p{javaLetterOrDigit}", "\\w"),
            ("\\p{javaLetter}",        "[\\p{L}]"),
            ("\\P{javaLetterOrDigit}", "\\W"),
            ("\\p{javaUpperCase}",     "\\p{Lu}"),
            ("\\p{javaLowerCase}",     "\\p{Ll}"),
            ("\\p{javaWhitespace}",    "\\s"),
            ("\\p{javaMirrored}",      "."),
        ]
        for (java, icu) in replacements {
            r = r.replacingOccurrences(of: java, with: icu)
        }
        return r
    }
}
