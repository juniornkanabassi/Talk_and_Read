import XCTest
@testable import TalkReadCore

final class ScaffoldTests: XCTestCase {
    func testTokenizerSplitsWordsAndSentences() {
        let tokens = TextKit.tokenize("Hello, world. It's 3 pm!")
        XCTAssertEqual(tokens.map(\.text), ["Hello", "world", "It's", "3", "pm"])
        XCTAssertEqual(tokens.map(\.sentence), [0, 0, 1, 1, 1])
        XCTAssertEqual(tokens[1].range, 7..<12)
    }
}
