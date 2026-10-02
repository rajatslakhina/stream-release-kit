import XCTest
@testable import StreamReleaseKit

final class ReleaseGateTests: XCTestCase {
    private var aws: PatternScanner { get throws { try .awsAccessKeyID() } }
    private var email: PatternScanner { get throws { try .emailAddress() } }
    private let canary = LiteralScanner(name: "canary", phrase: "ZEBRA-7731", action: .block(reason: "leak"))

    func testSecretSplitAcrossDeltasIsRedacted() async throws {
        let result = await stream(["Use key AKIAIOSF", "ODNN7EXAMPLE now."], through: [try aws])
        XCTAssertEqual(result.text, "Use key [AWS-KEY] now.")
        let stats = await result.gate.stats
        XCTAssertEqual(stats.redactions, 1)
        XCTAssertEqual(stats.chunks, 2)
        XCTAssertEqual(stats.scalarsReceived, 33)
        XCTAssertEqual(stats.scalarsReleased, 33)
    }

    func testEveryTwoWaySplitMatchesReference() async throws {
        let scanners: [any StreamScanner] = [try aws, try email, canary]
        let inputs = [
            "Mail ops@acme.io or bob.smith@example.org; key AKIAJ5Q2EXAMPLEKEY12 rotates.",
            "AKIAIOSFODNN7EXAMPLE",
            "x@y.io",
            "é then e\u{301}: café@ex.com 🙂 AKIAIOSFODNN7EXAMPLE",
            "Safe text then ZEBRA-7731 then AKIAIOSFODNN7EXAMPLE never shown"
        ]
        for input in inputs {
            let reference = await ReleaseGate.reference(for: input, scanners: scanners)
            for cut in 0...input.unicodeScalars.count {
                let shown = await stream(split(input, at: [cut]), through: scanners).text
                XCTAssertEqual(shown, reference, "cut \(cut) of \(input)")
            }
        }
    }

    func testRandomMultiWaySplitsMatchReference() async throws {
        let scanners: [any StreamScanner] = [try aws, try email]
        let input = String(repeating: "ping a.b@c.dev, AKIAIOSFODNN7EXAMPLE; ", count: 4)
        let reference = await ReleaseGate.reference(for: input, scanners: scanners)
        XCTAssertEqual(reference, String(repeating: "ping [EMAIL], [AWS-KEY]; ", count: 4))
        var rng = SplitMix(state: 42)
        let length = input.unicodeScalars.count
        for _ in 0..<60 {
            let cuts = (0..<Int.random(in: 1...12, using: &rng)).map { _ in Int.random(in: 0...length, using: &rng) }
            let shown = await stream(split(input, at: cuts), through: scanners).text
            XCTAssertEqual(shown, reference, "cuts \(cuts.sorted())")
        }
    }

    func testReleasesOnlyBeyondHoldback() async throws {
        let gate = ReleaseGate(scanners: [canary])
        XCTAssertEqual(gate.holdback, 9)
        let first = await gate.ingest("0123456789ABC")
        XCTAssertEqual(first.text, "0123")
        XCTAssertEqual(first.withheld, 9)
        XCTAssertEqual(first.status, .streaming)
        let last = await gate.finish()
        XCTAssertEqual(last.text, "456789ABC")
        XCTAssertEqual(last.status, .finished)
        XCTAssertEqual(last.withheld, 0)
        let peak = await gate.stats.peakWithheld
        XCTAssertEqual(peak, 9)
    }

    func testBlockReleasesPrefixThenDropsEverything() async throws {
        let gate = ReleaseGate(scanners: [canary])
        var shown = await gate.ingest("Sure, it is zebra-77").text
        let blocked = await gate.ingest("31 and more text here")
        shown += blocked.text
        XCTAssertEqual(shown, "Sure, it is ")
        XCTAssertEqual(blocked.status, .blocked(rule: "canary", reason: "leak"))
        XCTAssertEqual(blocked.findings, [ReleaseFinding(rule: "canary", range: 12..<22, action: .block(reason: "leak"))])
        XCTAssertEqual(blocked.withheld, 0)
        let dropped = await gate.ingest("ignored")
        XCTAssertEqual(dropped, Release(text: "", findings: [], status: blocked.status, withheld: 0))
        let finished = await gate.finish()
        XCTAssertEqual(finished.status, blocked.status)
        XCTAssertEqual(finished.text, "")
        let stats = await gate.stats
        XCTAssertEqual(stats.chunksDropped, 1)
        XCTAssertEqual(stats.scalarsReleased, 12)
    }

    func testRedactionBeforeBlockIsKept() async throws {
        let result = await stream(["AKIAIOSFODNN7EXAMPLE then ZEBRA-7731 tail"], through: [try aws, canary])
        XCTAssertEqual(result.text, "[AWS-KEY] then ")
    }

    func testFinishTwiceReturnsNothingMore() async {
        let gate = ReleaseGate(scanners: [canary])
        _ = await gate.ingest("hello")
        let first = await gate.finish()
        XCTAssertEqual(first.text, "hello")
        let second = await gate.finish()
        XCTAssertEqual(second, Release(text: "", findings: [], status: .finished, withheld: 0))
        let late = await gate.ingest("late")
        XCTAssertEqual(late.text, "")
    }

    func testOverlapPrefersEarliestThenLongestThenScannerOrder() async throws {
        let short = try PatternScanner(name: "short", pattern: "ab", maxMatchLength: 2, context: 0, action: .redact(replacement: "S"))
        let long = try PatternScanner(name: "long", pattern: "abc", maxMatchLength: 3, context: 0, action: .redact(replacement: "L"))
        let twin = try PatternScanner(name: "twin", pattern: "abc", maxMatchLength: 3, context: 0, action: .redact(replacement: "T"))
        let late = try PatternScanner(name: "late", pattern: "bcd", maxMatchLength: 3, context: 0, action: .redact(replacement: "X"))
        let shown = await ReleaseGate.reference(for: "-abcd-", scanners: [short, late, twin, long])
        XCTAssertEqual(shown, "-Td-")
    }

    func testNoScannersPassesThroughImmediately() async {
        let gate = ReleaseGate(scanners: [])
        XCTAssertEqual(gate.holdback, 0)
        let release = await gate.ingest("abc")
        XCTAssertEqual(release.text, "abc")
        XCTAssertEqual(release.withheld, 0)
    }

    func testEmptyMatchesAreIgnored() async {
        struct EmptyScanner: StreamScanner {
            let name = "empty"
            let maxMatchLength = 1
            let context = 0
            func matches(in text: String) -> [ScanMatch] {
                [ScanMatch(range: 0..<0, rule: name, action: .block(reason: "never"))]
            }
        }
        let shown = await ReleaseGate.reference(for: "abc", scanners: [EmptyScanner()])
        XCTAssertEqual(shown, "abc")
    }

    func testMatchAlreadyReleasedIsNotAppliedTwice() async throws {
        // The left-context window re-scans the scalar before `committed`, where the
        // first delta's redaction already happened.
        let scanner = try PatternScanner(name: "x", pattern: "x", maxMatchLength: 1, action: .redact(replacement: "#"))
        let gate = ReleaseGate(scanners: [scanner])
        let first = await gate.ingest("xa")
        XCTAssertEqual(first.text, "#")
        let second = await gate.ingest("b")
        let last = await gate.finish()
        XCTAssertEqual(first.text + second.text + last.text, "#ab")
        let redactions = await gate.stats.redactions
        XCTAssertEqual(redactions, 1)
    }

    func testStatusIsBlockedHelper() {
        XCTAssertFalse(ReleaseStatus.streaming.isBlocked)
        XCTAssertFalse(ReleaseStatus.finished.isBlocked)
        XCTAssertTrue(ReleaseStatus.blocked(rule: "r", reason: "x").isBlocked)
    }
}
