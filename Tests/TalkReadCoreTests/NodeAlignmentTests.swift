import XCTest
@testable import TalkReadCore

final class NodeAlignmentTests: XCTestCase {
    /// A long read: when the map was built only the opening was exposed; once the reader scrolls, the app's AX tree
    /// holds the later words but no longer the opening ones. Anchoring on the selection's first words (the old map)
    /// finds nothing, so the box stopped; anchoring on the spoken word maps the rest of the read.
    func testLongReadRealignsFromTheSpokenWord() {
        let selection = "one two three four five six seven eight nine ten eleven twelve".split(separator: " ").map(String.init)
        let laterStream = ["sidebar", "new", "chat"] + Array(selection[6...]) + ["reply", "copy"]
        XCTAssertEqual(NodeAlignment.best(laterStream, selection), [:])
        XCTAssertEqual(NodeAlignment.best(laterStream, selection, from: 6), [6: 3, 7: 4, 8: 5, 9: 6, 10: 7, 11: 8])
    }

    /// Mid-text, toolbar text that repeats the spoken phrase loses to the copy preceded by the selection's own words,
    /// a lone final word is placed by its context, and evidence that conflicts hides the words instead of guessing.
    func testMidTextAnchorUsesPrecedingContext() {
        let selection = ["distinct", "opening", "context", "in", "the", "end"]
        let stream = ["in", "the", "end", "share", "distinct", "opening", "context", "in", "the", "end"]
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 3), [3: 7, 4: 8, 5: 9])
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 5), [5: 9])
        XCTAssertEqual(NodeAlignment.best(["in", "the", "end", "share", "in", "the", "end"], selection, from: 3), [:])
        // A lone toolbar word never stands in for the document text, and a longer forward run loses to context.
        XCTAssertEqual(NodeAlignment.best(["share", "copy"], ["please", "keep", "a", "copy"], from: 3), [:])
        let copy = ["please", "keep", "a", "copy", "of", "this", "now"]
        let stream2 = ["copy", "of", "this", "now", "please", "keep", "a", "copy", "of", "this"]
        XCTAssertEqual(NodeAlignment.best(stream2, copy, from: 3), [3: 7, 4: 8, 5: 9])
        // Repetition inside the selection: context that settles it wins; context against coverage hides.
        let send = "please keep a copy of this now and send me a copy of this".split(separator: " ").map(String.init)
        XCTAssertEqual(NodeAlignment.best(Array(send[3...10]) + Array(send[0...5]), send, from: 3), [:])
        let step = "we can begin today the next step is to check the inputs and run the tests we cannot start today the next step is to wait for approval".split(separator: " ").map(String.init)
        XCTAssertEqual(NodeAlignment.best(Array(step[4...]), step, from: 4), [:])
        // A preview whose resync borrows the body's words cannot outvote the body.
        let file = "please keep a copy of this file for your records".split(separator: " ").map(String.init)
        let preview = ["please", "keep", "a", "copy", "of", "this", "now", "share"] + Array(file[3...])
        XCTAssertEqual(NodeAlignment.best(preview, file, from: 3), [:])
        // Equal context with only coverage to tell copies apart hides.
        let reference = "for future reference please keep a copy of this file for your records".split(separator: " ").map(String.init)
        XCTAssertEqual(NodeAlignment.best(Array(reference[3...]) + ["share"] + Array(reference[3...8]), reference, from: 6), [:])
    }

    /// Mid-text only the validated unbroken run is kept, so words past a resync (a toolbar "copy" after the exposed
    /// text ends) are never placed without their own evidence.
    func testMidTextKeepsOnlyTheUnbrokenRun() {
        let selection = "after the meeting now review the project plan before lunch and keep a copy".split(separator: " ").map(String.init)
        let stream = ["now", "review", "the", "project", "plan", "before", "lunch", "share", "copy"]
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 3), [3: 0, 4: 1, 5: 2, 6: 3, 7: 4, 8: 5, 9: 6])
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 13), [:])
        let day = "we met at the end of the day and talked at the end of the day".split(separator: " ").map(String.init)
        XCTAssertEqual(NodeAlignment.best(day, day, from: 11), [11: 11, 12: 12, 13: 13, 14: 14, 15: 15])
    }

    /// 1.0.3's known limit: Chromium's exposed text ends mid-sentence right before a "Copy" button, and the selection's
    /// next word is "copy". Flattened as plain text (1.0.3) the run steps onto the button label; marked as chrome it
    /// stops at the cut, from the selection's start and mid-text alike, and the words before the cut are unchanged.
    func testRunsStopAtUILabels() {
        let selection = "after the meeting now review the project plan before lunch and keep a copy of the notes".split(separator: " ").map(String.init)
        let text = "after the meeting now review the project plan before lunch and keep a"
        func words(chrome: Bool) -> [String] {
            NodeAlignment.stream([("New chat", true), (text, false), ("Copy", chrome), ("Retry", chrome)]).map(\.word)
        }
        let flat = words(chrome: false), guarded = words(chrome: true)
        XCTAssertEqual(guarded, ["", ""] + selection[0..<13].map { $0 } + ["", ""])
        for start in [0, 6] {
            XCTAssertEqual(NodeAlignment.best(flat, selection, from: start)[13], 15) // 1.0.3: "copy" on the button
            let map = NodeAlignment.best(guarded, selection, from: start)
            XCTAssertNil(map[13])
            XCTAssertEqual(map, NodeAlignment.best(flat, selection, from: start).filter { $0.key < 13 })
        }
    }

    /// Chrome is inherited down from a chrome element, but a tab group is not chrome: it holds the tabs and the page.
    func testChromeFollowsAncestry() {
        let tabGroup = NodeAlignment.isChrome(role: "AXTabGroup", parentChrome: false)
        XCTAssertFalse(tabGroup)
        XCTAssertTrue(NodeAlignment.isChrome(role: "AXRadioButton", parentChrome: tabGroup)) // a tab
        XCTAssertTrue(NodeAlignment.isChrome(role: "AXStaticText", parentChrome: true))       // the tab's label
        let page = NodeAlignment.isChrome(role: "AXWebArea", parentChrome: tabGroup)
        XCTAssertFalse(NodeAlignment.isChrome(role: "AXStaticText", parentChrome: page))      // the page's text
        XCTAssertFalse(NodeAlignment.isChrome(role: nil, parentChrome: false))
        XCTAssertTrue(NodeAlignment.isChrome(role: "AXStaticText", parentChrome: NodeAlignment.isChrome(role: "AXToolbar", parentChrome: false)))
    }

    /// Selection starts mid-stream, with one stray word ("really") in the stream that must be skipped.
    func testAlignmentSkipsStrayStreamWords() {
        let map = NodeAlignment.alignStream(["intro", "the", "quick", "really", "brown", "fox", "jumps"], ["quick", "brown", "fox", "jumps"], startingAt: 2)
        XCTAssertEqual(map, [0: 2, 1: 4, 2: 5, 3: 6])
        XCTAssertEqual(NodeAlignment.alignStream(["one", "two", "three", "wrong"], ["one", "two", "three", "four", "five", "six"], startingAt: 0), [0: 0, 1: 1, 2: 2])
    }

    /// A note's tab title repeats its opening words and can reach the same match count as the real body
    /// before resyncing far away in the stream; the tighter (contiguous) alignment must win the tie.
    func testTieGoesToTheContiguousAlignment() {
        let contiguous: [Int: Int] = [0: 10, 1: 11, 2: 12]
        let gappy: [Int: Int] = [0: 10, 1: 11, 2: 50]
        XCTAssertTrue(NodeAlignment.better(contiguous, than: gappy))
        XCTAssertFalse(NodeAlignment.better(gappy, than: contiguous))
    }

    // MARK: repeated phrases (PLAN decision 13)

    private func w(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    /// The same phrase on screen twice and nothing says which is the selection: hide. `prefer` (the capture element's
    /// subtree) picks the single copy inside it; a copy outside it, or both, or neither, still hides.
    func testRepeatedPhraseNeedsPreferToBeBoxed() {
        let phrase = w("please review the attached budget before friday")
        let stream = ["inbox", "preview"] + phrase + ["share", "reply", "message", "body"] + phrase + ["thanks"]
        let first = 2, second = 2 + phrase.count + 4
        XCTAssertEqual(NodeAlignment.best(stream, phrase), [:])
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: nil), [:])
        let inSecond = Set(second..<(second + phrase.count)), inFirst = Set(first..<(first + phrase.count))
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: inSecond), Dictionary(uniqueKeysWithValues: phrase.indices.map { ($0, second + $0) }))
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: inFirst), Dictionary(uniqueKeysWithValues: phrase.indices.map { ($0, first + $0) }))
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: inFirst.union(inSecond)), [:])
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: [0, 1, stream.count - 1]), [:])
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: []), [:])
        // a prefer set that only partly covers one copy does not count as inside
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: Set(second..<(second + phrase.count - 1))), [:])
    }

    /// A single complete match is used whatever `prefer` says: it only settles ties.
    func testSingleMatchIgnoresPrefer() {
        let phrase = w("please review the attached budget before friday")
        let stream = ["x"] + phrase + ["y"]
        let expected = Dictionary(uniqueKeysWithValues: phrase.indices.map { ($0, 1 + $0) })
        XCTAssertEqual(NodeAlignment.best(stream, phrase), expected)
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: [0]), expected)
        XCTAssertEqual(NodeAlignment.best(stream, phrase, prefer: Set(1...phrase.count)), expected)
    }

    /// A tab title that repeats the opening words but resyncs across a wide gap is not an equally good match.
    func testWideSpanCopyIsNotATie() {
        let phrase = w("meeting notes from the quarterly planning session today")
        let stream = ["meeting", "notes", "from"] + ["tab", "bar", "sidebar", "new", "chat", "settings", "x", "y"] + phrase
        let expected = Dictionary(uniqueKeysWithValues: phrase.indices.map { ($0, 11 + $0) })
        XCTAssertEqual(NodeAlignment.best(stream, phrase), expected)
    }

    /// Repeats that are only partial are not "complete" ties: the longer alignment wins as before.
    func testPartialRepeatLosesToCompleteMatch() {
        let phrase = w("alpha beta gamma delta epsilon zeta")
        let stream = w("alpha beta gamma other words") + w("pad pad pad") + phrase
        XCTAssertEqual(NodeAlignment.best(stream, phrase), Dictionary(uniqueKeysWithValues: phrase.indices.map { ($0, 8 + $0) }))
    }

    /// Mid-text behaviour is unchanged by `prefer`.
    func testMidTextUnchangedByPrefer() {
        let selection = ["distinct", "opening", "context", "in", "the", "end"]
        let stream = ["in", "the", "end", "share", "distinct", "opening", "context", "in", "the", "end"]
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 3, prefer: [0, 1, 2]), [3: 7, 4: 8, 5: 9])
        XCTAssertEqual(NodeAlignment.best(stream, selection, from: 3, prefer: nil), [3: 7, 4: 8, 5: 9])
        XCTAssertEqual(NodeAlignment.best(["in", "the", "end", "share", "in", "the", "end"], selection, from: 3, prefer: [4, 5, 6]), [:])
    }
}
