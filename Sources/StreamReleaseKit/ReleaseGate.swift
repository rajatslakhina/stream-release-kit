/// Holds back the tail of a streamed reply until no scanner can still change its verdict on it.
///
/// Scanning each chunk on its own misses a secret split across two chunks, and scanning the
/// finished reply is too late, because the text is already on screen. The gate keeps the last
/// `holdback` scalars back, scans the stream as one text, and releases only what is decided.
/// For local scanners (see `StreamScanner`) the concatenated releases equal `reference(for:)`
/// of the whole reply, however the stream was split.
public actor ReleaseGate {
    public nonisolated let holdback: Int
    private let scanners: [any StreamScanner]
    private let context: Int
    private var raw: [Unicode.Scalar] = []
    private var committed = 0
    private var status: ReleaseStatus = .streaming
    public private(set) var stats = ReleaseStats()

    public init(scanners: [any StreamScanner]) {
        self.scanners = scanners
        self.holdback = scanners.map(\.holdback).max() ?? 0
        self.context = scanners.map(\.context).max() ?? 0
    }

    /// Adds a chunk and returns whatever is now safe to show.
    public func ingest(_ chunk: String) -> Release {
        stats.chunks += 1
        stats.scalarsReceived += chunk.unicodeScalars.count
        guard case .streaming = status else {
            stats.chunksDropped += 1
            return Release(text: "", findings: [], status: status, withheld: 0)
        }
        raw.append(contentsOf: chunk.unicodeScalars)
        return advance(to: max(committed, raw.count - holdback), final: false)
    }

    /// Ends the stream and releases everything still held back.
    public func finish() -> Release {
        guard case .streaming = status else {
            return Release(text: "", findings: [], status: status, withheld: 0)
        }
        return advance(to: raw.count, final: true)
    }

    /// What the gate would release for `text` delivered in one piece.
    public static func reference(for text: String, scanners: [any StreamScanner]) async -> String {
        let gate = ReleaseGate(scanners: scanners)
        let first = await gate.ingest(text)
        let last = await gate.finish()
        return first.text + last.text
    }

    private func advance(to target: Int, final: Bool) -> Release {
        let decided = resolvedMatches()
        var boundary = target
        if let straddling = decided.first(where: { $0.range.lowerBound < boundary && $0.range.upperBound > boundary }) {
            boundary = straddling.range.lowerBound
        }
        var output = ""
        var findings: [ReleaseFinding] = []
        var cursor = committed
        for match in decided where match.range.lowerBound < boundary {
            output += text(cursor..<match.range.lowerBound)
            findings.append(ReleaseFinding(rule: match.rule, range: match.range, action: match.action))
            switch match.action {
            case .redact(let replacement):
                output += replacement
                cursor = match.range.upperBound
                stats.redactions += 1
            case .block(let reason):
                status = .blocked(rule: match.rule, reason: reason)
                return close(output: output, findings: findings, consumed: match.range.lowerBound)
            }
        }
        output += text(cursor..<boundary)
        committed = boundary
        if final { status = .finished }
        stats.scalarsReleased = committed
        stats.peakWithheld = max(stats.peakWithheld, raw.count - committed)
        return Release(text: output, findings: findings, status: status, withheld: raw.count - committed)
    }

    private func close(output: String, findings: [ReleaseFinding], consumed: Int) -> Release {
        committed = consumed
        stats.scalarsReleased = consumed
        return Release(text: output, findings: findings, status: status, withheld: 0)
    }

    /// Matches that start at or after the committed point, earliest first, overlaps dropped.
    private func resolvedMatches() -> [ScanMatch] {
        let windowStart = max(0, committed - context)
        let window = text(windowStart..<raw.count)
        var candidates: [(match: ScanMatch, order: Int)] = []
        for (order, scanner) in scanners.enumerated() {
            for found in scanner.matches(in: window) where !found.range.isEmpty {
                let range = (found.range.lowerBound + windowStart)..<(found.range.upperBound + windowStart)
                guard range.lowerBound >= committed else { continue }
                candidates.append((ScanMatch(range: range, rule: found.rule, action: found.action), order))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.match.range.lowerBound != rhs.match.range.lowerBound {
                return lhs.match.range.lowerBound < rhs.match.range.lowerBound
            }
            if lhs.match.range.count != rhs.match.range.count {
                return lhs.match.range.count > rhs.match.range.count
            }
            return lhs.order < rhs.order
        }
        var picked: [ScanMatch] = []
        var end = 0
        for candidate in candidates where candidate.match.range.lowerBound >= end {
            picked.append(candidate.match)
            end = candidate.match.range.upperBound
        }
        return picked
    }

    private func text(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: raw[range])
        return String(view)
    }
}
