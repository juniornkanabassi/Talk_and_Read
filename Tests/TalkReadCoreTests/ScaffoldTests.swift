import XCTest
@testable import TalkReadCore

final class ScaffoldTests: XCTestCase {
    func testTokenizerSplitsWordsAndSentences() {
        let tokens = TextKit.tokenize("Hello, world. It's 3 pm!")
        XCTAssertEqual(tokens.map(\.text), ["Hello", "world", "It's", "3", "pm"])
        XCTAssertEqual(tokens.map(\.sentence), [0, 0, 1, 1, 1])
        XCTAssertEqual(tokens[1].range, 7..<12)
    }

    func testUpdateCacheClearedOnlyWhenTheBuildChanges() {
        XCTAssertTrue(UpdateCache.shouldClear(lastLaunched: nil, running: "7"))
        XCTAssertTrue(UpdateCache.shouldClear(lastLaunched: "7", running: "8"))
        XCTAssertTrue(UpdateCache.shouldClear(lastLaunched: "8", running: "7"))
        XCTAssertFalse(UpdateCache.shouldClear(lastLaunched: "8", running: "8"))
        let caches = URL(fileURLWithPath: "/Users/x/Library/Caches")
        XCTAssertEqual(UpdateCache.folder(bundleID: "com.juniornkanabassi.TalkAndRead", caches: caches).path,
                       "/Users/x/Library/Caches/com.juniornkanabassi.TalkAndRead/org.sparkle-project.Sparkle")
    }
}
