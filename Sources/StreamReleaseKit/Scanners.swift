import Foundation

/// A regular-expression scanner. The pattern must not match more than `maxMatchLength`
/// scalars; use bounded quantifiers (`{1,32}`, never `+` or `*`).
public struct PatternScanner: StreamScanner {
    public let name: String
    public let maxMatchLength: Int
    public let context: Int
    public let action: MatchAction
    private let compiled: CompiledPattern

    public init(
        name: String,
        pattern: String,
        maxMatchLength: Int,
        context: Int = 1,
        caseInsensitive: Bool = false,
        action: MatchAction
    ) throws {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        self.compiled = CompiledPattern(regex: try NSRegularExpression(pattern: pattern, options: options))
        self.name = name
        self.maxMatchLength = maxMatchLength
        self.context = context
        self.action = action
    }

    public func matches(in text: String) -> [ScanMatch] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return compiled.regex.matches(in: text, range: whole).map { result in
            let start = String.Index(utf16Offset: result.range.location, in: text)
            let end = String.Index(utf16Offset: NSMaxRange(result.range), in: text)
            let lower = text.unicodeScalars.distance(from: text.startIndex, to: start)
            let length = text.unicodeScalars.distance(from: start, to: end)
            return ScanMatch(range: lower..<(lower + length), rule: name, action: action)
        }
    }
}

/// NSRegularExpression is immutable after creation and documented as safe to use from
/// multiple threads; it is not marked Sendable on every SDK this package supports.
private final class CompiledPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(regex: NSRegularExpression) {
        self.regex = regex
    }
}

extension PatternScanner {
    /// AWS access key IDs (`AKIA` + 16 uppercase alphanumerics).
    public static func awsAccessKeyID(replacement: String = "[AWS-KEY]") throws -> PatternScanner {
        try PatternScanner(
            name: "aws-access-key-id",
            pattern: #"\bAKIA[0-9A-Z]{16}\b"#,
            maxMatchLength: 20,
            action: .redact(replacement: replacement)
        )
    }

    /// Email addresses with a bounded local part and domain (at most 96 scalars).
    public static func emailAddress(replacement: String = "[EMAIL]") throws -> PatternScanner {
        try PatternScanner(
            name: "email-address",
            pattern: #"\b[A-Za-z0-9._%+-]{1,32}@[A-Za-z0-9-]{1,30}(?:\.[A-Za-z0-9-]{1,30}){0,2}\.[A-Za-z]{2,6}\b"#,
            maxMatchLength: 96,
            action: .redact(replacement: replacement)
        )
    }
}

/// Flags a fixed phrase, case-insensitively. Useful for canary tokens and system-prompt
/// fragments that must never reach the user.
public struct LiteralScanner: StreamScanner {
    public let name: String
    public let action: MatchAction
    public let context = 0
    private let needle: [String]

    public init(name: String, phrase: String, action: MatchAction) {
        self.name = name
        self.action = action
        self.needle = phrase.unicodeScalars.map(Self.fold)
    }

    public var maxMatchLength: Int { needle.count }

    public func matches(in text: String) -> [ScanMatch] {
        // Folded one scalar at a time, so offsets stay in the caller's scalar coordinates
        // even where lowercasing the whole string would change its length.
        let hay = text.unicodeScalars.map(Self.fold)
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var found: [ScanMatch] = []
        var index = 0
        while index + needle.count <= hay.count {
            if hay[index..<(index + needle.count)].elementsEqual(needle) {
                found.append(ScanMatch(range: index..<(index + needle.count), rule: name, action: action))
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    private static func fold(_ scalar: Unicode.Scalar) -> String {
        String(scalar).lowercased()
    }
}
