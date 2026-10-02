/// Where a gate's stream stands after a call.
public enum ReleaseStatus: Sendable, Equatable {
    /// More text may arrive; some of it may still be withheld.
    case streaming
    /// `finish()` was called and everything left has been released.
    case finished
    /// A blocking rule matched. Nothing after the match is ever released.
    case blocked(rule: String, reason: String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// A span the gate acted on, in Unicode-scalar offsets of the raw stream.
public struct ReleaseFinding: Sendable, Equatable {
    public let rule: String
    public let range: Range<Int>
    public let action: MatchAction

    public init(rule: String, range: Range<Int>, action: MatchAction) {
        self.rule = rule
        self.range = range
        self.action = action
    }
}

/// What one `ingest` or `finish` call lets through.
public struct Release: Sendable, Equatable {
    /// Text that is now safe to show. Append it to what was shown before.
    public let text: String
    /// Spans decided during this call.
    public let findings: [ReleaseFinding]
    public let status: ReleaseStatus
    /// Raw scalars received but not yet released after this call.
    public let withheld: Int

    public init(text: String, findings: [ReleaseFinding], status: ReleaseStatus, withheld: Int) {
        self.text = text
        self.findings = findings
        self.status = status
        self.withheld = withheld
    }
}

/// Running totals for one stream.
public struct ReleaseStats: Sendable, Equatable {
    public var chunks = 0
    public var scalarsReceived = 0
    public var scalarsReleased = 0
    public var redactions = 0
    /// Chunks that arrived after a block and were dropped unread.
    public var chunksDropped = 0
    /// The most raw scalars ever held back at once: the latency the gate cost.
    public var peakWithheld = 0

    public init() {}
}
