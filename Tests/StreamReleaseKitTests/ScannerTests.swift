import XCTest
@testable import StreamReleaseKit

final class ScannerTests: XCTestCase {
    func testHoldbackIsMaxLengthMinusOnePlusContext() throws {
        XCTAssertEqual(try PatternScanner.awsAccessKeyID().holdback, 20)
        XCTAssertEqual(try PatternScanner.emailAddress().holdback, 96)
        XCTAssertEqual(LiteralScanner(name: "c", phrase: "abc", action: .block(reason: "r")).holdback, 2)
        XCTAssertEqual(LiteralScanner(name: "c", phrase: "", action: .block(reason: "r")).holdback, 0)
    }

    func testAWSKeyMatchesInScalarOffsets() throws {
        let scanner = try PatternScanner.awsAccessKeyID()
        let found = scanner.matches(in: "🙂 key AKIAIOSFODNN7EXAMPLE.")
        XCTAssertEqual(found, [ScanMatch(range: 6..<26, rule: "aws-access-key-id", action: .redact(replacement: "[AWS-KEY]"))])
        XCTAssertTrue(scanner.matches(in: "AKIAIOSFODNN7EXAMPLEX").isEmpty, "word boundary required")
    }

    func testEmailScanner() throws {
        let scanner = try PatternScanner.emailAddress(replacement: "<e>")
        let found = scanner.matches(in: "a jane.doe@example.co.uk b")
        XCTAssertEqual(found.map(\.range), [2..<24])
        XCTAssertEqual(found.first?.action, .redact(replacement: "<e>"))
    }

    func testCaseInsensitivePattern() throws {
        let scanner = try PatternScanner(
            name: "x", pattern: "secret", maxMatchLength: 6, caseInsensitive: true, action: .block(reason: "r")
        )
        XCTAssertEqual(scanner.matches(in: "a SeCrEt").map(\.range), [2..<8])
        XCTAssertEqual(scanner.context, 1)
    }

    func testInvalidPatternThrows() {
        XCTAssertThrowsError(try PatternScanner(name: "bad", pattern: "(", maxMatchLength: 1, action: .block(reason: "r")))
    }

    func testLiteralScannerFoldsPerScalarAndSkipsOverlaps() {
        let scanner = LiteralScanner(name: "c", phrase: "AaA", action: .block(reason: "r"))
        XCTAssertEqual(scanner.matches(in: "aaaaa").map(\.range), [0..<3])
        XCTAssertEqual(scanner.matches(in: "xaAaxAAA").map(\.range), [1..<4, 5..<8])
        XCTAssertTrue(scanner.matches(in: "aa").isEmpty)
    }

    func testLiteralScannerKeepsOffsetsWhenLowercasingChangesLength() {
        // "İ" lowercases to two scalars; offsets must still be the caller's.
        let scanner = LiteralScanner(name: "c", phrase: "zebra", action: .block(reason: "r"))
        XCTAssertEqual(scanner.matches(in: "İİ ZEBRA").map(\.range), [3..<8])
    }

    func testEmptyLiteralNeverMatches() {
        XCTAssertTrue(LiteralScanner(name: "c", phrase: "", action: .block(reason: "r")).matches(in: "abc").isEmpty)
    }
}
