import XCTest

@testable import MurmurKit

final class TextMatchTests: XCTestCase {
    func testNormalizeLowersStripsAndCollapses() {
        XCTAssertEqual(TextMatch.normalize("Hello,  World!"), "hello world")
        XCTAssertEqual(TextMatch.normalize("Testing 123."), "testing 123")
        XCTAssertEqual(TextMatch.normalize("  a\n b\tc "), "a b c")
        XCTAssertEqual(TextMatch.normalize(""), "")
        XCTAssertEqual(TextMatch.normalize("..."), "")
    }

    func testWERExactMatchIsZero() {
        XCTAssertEqual(TextMatch.wer(reference: "the quick brown fox", hypothesis: "The quick brown fox."), 0)
    }

    func testWEROneSubstitutionInFour() {
        XCTAssertEqual(TextMatch.wer(reference: "a b c d", hypothesis: "a b x d"), 0.25, accuracy: 1e-9)
    }

    func testWERInsertionAndDeletion() {
        XCTAssertEqual(TextMatch.wer(reference: "a b c", hypothesis: "a b"), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(TextMatch.wer(reference: "a b", hypothesis: "a x b"), 0.5, accuracy: 1e-9)
    }

    func testWEREmptyHypothesisAgainstNonEmptyReference() {
        XCTAssertEqual(TextMatch.wer(reference: "a b", hypothesis: ""), 1.0)
    }
}
