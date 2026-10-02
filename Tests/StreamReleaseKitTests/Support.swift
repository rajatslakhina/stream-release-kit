import StreamReleaseKit

func split(_ text: String, at cuts: [Int]) -> [String] {
    let scalars = Array(text.unicodeScalars)
    var bounds = [0] + cuts.sorted() + [scalars.count]
    bounds = bounds.map { min(max($0, 0), scalars.count) }
    return zip(bounds, bounds.dropFirst()).map { lower, upper in
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lower..<max(lower, upper)])
        return String(view)
    }
}

func stream(_ deltas: [String], through scanners: [any StreamScanner]) async -> (text: String, gate: ReleaseGate) {
    let gate = ReleaseGate(scanners: scanners)
    var shown = ""
    for delta in deltas {
        shown += await gate.ingest(delta).text
    }
    shown += await gate.finish().text
    return (shown, gate)
}

/// Deterministic generator so random-split tests reproduce.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct FailingChunks: AsyncSequence, Sendable {
    typealias Element = String
    struct Boom: Error {}
    let before: [String]

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: [String]
        mutating func next() async throws -> String? {
            guard !remaining.isEmpty else { throw Boom() }
            return remaining.removeFirst()
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: before) }
}

func deltas(_ items: [String]) -> AsyncStream<String> {
    AsyncStream { continuation in
        for item in items { continuation.yield(item) }
        continuation.finish()
    }
}
