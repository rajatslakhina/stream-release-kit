import XCTest
@testable import StreamReleaseKit

final class StreamPipeTests: XCTestCase {
    func testPipesDeltasAndFinishes() async throws {
        let gate = ReleaseGate(scanners: [try PatternScanner.emailAddress()])
        var releases: [Release] = []
        for try await release in gate.releases(of: deltas(["Contact ", "jane@exa", "mple.com", " now."])) {
            releases.append(release)
        }
        XCTAssertEqual(releases.count, 5)
        XCTAssertEqual(releases.map(\.text).joined(), "Contact [EMAIL] now.")
        XCTAssertEqual(releases.last?.status, .finished)
    }

    func testBlockEndsStreamEarly() async throws {
        let gate = ReleaseGate(scanners: [LiteralScanner(name: "c", phrase: "stop", action: .block(reason: "r"))])
        var releases: [Release] = []
        for try await release in gate.releases(of: deltas(["go go stop", " more", " and more"])) {
            releases.append(release)
        }
        // "stop" ends inside the holdback after delta 1, so the block is decided on delta 2
        // and delta 3 is never read.
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases.map(\.text).joined(), "go go ")
        XCTAssertEqual(releases.last?.status, .blocked(rule: "c", reason: "r"))
        let stats = await gate.stats
        XCTAssertEqual(stats.chunks, 2)
    }

    func testUpstreamErrorIsRethrownWithoutReleasingHeldText() async throws {
        let gate = ReleaseGate(scanners: [LiteralScanner(name: "c", phrase: "abcdef", action: .block(reason: "r"))])
        var shown = ""
        do {
            for try await release in gate.releases(of: FailingChunks(before: ["0123456789"])) {
                shown += release.text
            }
            XCTFail("expected error")
        } catch is FailingChunks.Boom {
            XCTAssertEqual(shown, "01234")
        }
    }
}
