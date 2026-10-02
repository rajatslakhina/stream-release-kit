/// What the gate does with a matched span.
public enum MatchAction: Sendable, Equatable {
    /// Replace the span with `replacement` and keep streaming.
    case redact(replacement: String)
    /// Release everything before the span, then stop releasing for good.
    case block(reason: String)
}

/// One span a scanner flagged, in Unicode-scalar offsets of the text it was given.
public struct ScanMatch: Sendable, Equatable {
    public let range: Range<Int>
    public let rule: String
    public let action: MatchAction

    public init(range: Range<Int>, rule: String, action: MatchAction) {
        self.range = range
        self.rule = rule
        self.action = action
    }
}

/// Finds dangerous spans in text.
///
/// A gate can only promise chunk-invariant output if a scanner is *local*: whether a span
/// matches must depend on the span itself plus at most `context` scalars either side of it,
/// and no match may be longer than `maxMatchLength` scalars. A scanner that breaks either
/// bound can see a different answer on a prefix than on the whole text, and the gate cannot
/// detect that. The built-in scanners keep both bounds by construction.
public protocol StreamScanner: Sendable {
    /// Rule name reported in findings.
    var name: String { get }
    /// Longest span this scanner can ever match, in Unicode scalars.
    var maxMatchLength: Int { get }
    /// Scalars of surrounding text a match decision may look at (for example `\b`).
    var context: Int { get }
    /// Every match in `text`, in any order. Offsets are Unicode-scalar offsets into `text`.
    func matches(in text: String) -> [ScanMatch]
}

extension StreamScanner {
    /// Trailing scalars whose verdict can still change when more text arrives.
    public var holdback: Int { max(0, maxMatchLength - 1) + context }
}
