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
        XCTAssertTrue(UpdateCache.isValidBundleID("com.juniornkanabassi.TalkAndRead"))
        XCTAssertTrue(UpdateCache.isValidBundleID("com.juniornkanabassi.TalkAndRead.updatetest.a1B2-c3"))
        for bad in ["", ".", "..", "../../Documents", "a/b", "com..x", ".com", "com.", "com x", "cöm"] {
            XCTAssertFalse(UpdateCache.isValidBundleID(bad), bad)
        }
    }

    /// The clean-up in a disposable home: it removes the Sparkle folder (files, nested folders, a link as a link) and
    /// never anything outside it, whatever the bundle id or symlinks say.
    func testUpdateCacheClearStaysInsideItsFolder() throws {
        let home = try makeTestDir("update-cache"), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches"), id = "com.test.app"
        func make(_ path: String, file: String = "keep", bytes: Int = 4) throws {
            let dir = home.appendingPathComponent(path)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent(file))
        }
        // Where a careless path could land: the shared Sparkle folder, Library, Documents, a link's target.
        let sentinels = ["Library/Caches/org.sparkle-project.Sparkle", "Library/org.sparkle-project.Sparkle",
                         "Documents/org.sparkle-project.Sparkle", "elsewhere/org.sparkle-project.Sparkle", "target", "outside"]
        for s in sentinels { try make(s) }
        func untouched() -> Bool { sentinels.allSatisfy { fm.fileExists(atPath: home.appendingPathComponent("\($0)/keep").path) } }

        for bad in ["", ".", "..", "../../Documents", "../Documents"] {
            XCTAssertThrowsError(try UpdateCache.clear(bundleID: bad, caches: caches), bad) { XCTAssertEqual($0 as? UpdateCache.Refusal, .invalidBundleID) }
            XCTAssertTrue(untouched(), bad)
        }
        XCTAssertNil(try UpdateCache.clear(bundleID: id, caches: caches))   // nothing there yet

        // A symlinked Caches/<bundle id>: refused; the link target's Sparkle folder stays.
        let parent = caches.appendingPathComponent(id)
        try fm.createSymbolicLink(at: parent, withDestinationURL: home.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try UpdateCache.clear(bundleID: id, caches: caches)) { XCTAssertEqual($0 as? UpdateCache.Refusal, .symlink(id)) }
        XCTAssertTrue(untouched())
        try fm.removeItem(at: parent)

        // A symlinked Sparkle folder: refused; the link and its target stay.
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let sparkle = parent.appendingPathComponent(UpdateCache.folderName)
        try fm.createSymbolicLink(at: sparkle, withDestinationURL: home.appendingPathComponent("target"))
        XCTAssertThrowsError(try UpdateCache.clear(bundleID: id, caches: caches)) { XCTAssertEqual($0 as? UpdateCache.Refusal, .symlink(UpdateCache.folderName)) }
        XCTAssertTrue(untouched() && (try? fm.destinationOfSymbolicLink(atPath: sparkle.path)) != nil)
        try fm.removeItem(at: sparkle)

        // The real case: files, a nested folder and a link inside go; the link's target and a sibling stay.
        try make("Library/Caches/\(id)/\(UpdateCache.folderName)/PersistentDownloads", file: "update.zip", bytes: 100)
        try make("Library/Caches/\(id)/\(UpdateCache.folderName)", file: "state", bytes: 20)
        try fm.createSymbolicLink(at: sparkle.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent("outside"))
        try make("Library/Caches/\(id)", file: "sibling")
        XCTAssertEqual(try UpdateCache.clear(bundleID: id, caches: caches), 120)
        XCTAssertFalse(fm.fileExists(atPath: sparkle.path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("sibling").path))
        XCTAssertTrue(untouched())
    }
}
