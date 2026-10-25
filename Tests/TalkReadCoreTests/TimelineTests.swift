import XCTest
@testable import TalkReadCore

final class TimelineTests: XCTestCase {
    /// Runs the whole path for one chunk: tokens of `source`, speakable text, then timings for `spoken`.
    private func run(_ source: String, lexicon: [String: String] = [:], spoken: [SpokenWord], offset: Double = 0, duration: Double,
                     tokenOffset: Int = 0) -> (tokens: [Token], speakable: Speakable, timings: [WordTiming]) {
        let tokens = TextKit.tokenize(source)
        let speakable = Speakable.make(source, range: 0..<(source as NSString).length, lexicon: lexicon)
        let timings = Timeline.timings(chunkTokens: tokens, chunkTokenOffset: tokenOffset, speakable: speakable, spoken: spoken, offset: offset, chunkDuration: duration)
        return (tokens, speakable, timings)
    }

    private func w(_ text: String, _ start: Double, _ end: Double, range: Range<Int>? = nil) -> SpokenWord {
        SpokenWord(text: text, start: start, end: end, range: range)
    }

    private func assertInvariants(_ t: [WordTiming], tokens: Int, tokenOffset: Int = 0, offset: Double, duration: Double,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.map(\.token), Array(tokenOffset..<(tokenOffset + tokens)), "one entry per token, in order", file: file, line: line)
        for (i, x) in t.enumerated() {
            XCTAssertGreaterThanOrEqual(x.start, offset, "token \(x.token)", file: file, line: line)
            XCTAssertLessThanOrEqual(x.end, offset + duration, "token \(x.token)", file: file, line: line)
            XCTAssertLessThanOrEqual(x.start, x.end, "token \(x.token)", file: file, line: line)
            if i > 0 {
                XCTAssertLessThanOrEqual(t[i - 1].end, x.start, "no overlap before token \(x.token)", file: file, line: line)
                XCTAssertLessThanOrEqual(t[i - 1].start, x.start, "monotonic starts", file: file, line: line)
            }
        }
    }

    func testPlainTimingIsOffsetAndKeepsTokenIndices() {
        let r = run("Hello big world", spoken: [w("Hello", 0, 0.4), w("big", 0.4, 0.6), w("world", 0.7, 1.2)], offset: 10, duration: 1.3, tokenOffset: 100)
        XCTAssertEqual(r.timings, [WordTiming(token: 100, start: 10, end: 10.4), WordTiming(token: 101, start: 10.4, end: 10.6), WordTiming(token: 102, start: 10.7, end: 11.2)])
        assertInvariants(r.timings, tokens: 3, tokenOffset: 100, offset: 10, duration: 1.3)
    }

    func testLexiconSubstitutionStillHighlightsTheSourceWord() {
        let r = run("Ask Nguyen now", lexicon: ["Nguyen": "win"], spoken: [w("ask", 0, 0.3), w("win", 0.3, 0.7), w("now", 0.7, 1.0)], duration: 1.0)
        XCTAssertEqual(r.speakable.text, "Ask win now")
        XCTAssertEqual(r.timings.map(\.start), [0, 0.3, 0.7])
        XCTAssertEqual(r.timings.map(\.end), [0.3, 0.7, 1.0])
    }

    func testASkippedCitationInsideAWordGetsNoTime() {
        let source = "Smith[12]'s view"
        let tokens = TextKit.tokenize(source)
        let sp = Speakable.make(source, range: 0..<(source as NSString).length, lexicon: [:], skipCitations: true)
        XCTAssertEqual(sp.text, "Smith's view")
        let t = Timeline.timings(chunkTokens: tokens, chunkTokenOffset: 0, speakable: sp,
                                 spoken: [w("Smith's", 0, 0.8, range: 0..<7), w("view", 0.8, 1.2, range: 8..<12)], offset: 0, chunkDuration: 1.2)
        for (i, token) in tokens.enumerated() where token.text == "12" { XCTAssertEqual(t[i].start, t[i].end, "the dropped mark is never lit") }
        assertInvariants(t, tokens: tokens.count, offset: 0, duration: 1.2)
    }

    func testExpansionPoundsFortyFive() {
        let r = run("It costs £45 today", spoken: [w("it", 0, 0.2), w("costs", 0.2, 0.6), w("forty", 0.6, 0.9), w("five", 0.9, 1.1), w("pounds", 1.1, 1.5), w("today", 1.5, 2.0)], duration: 2.0)
        XCTAssertEqual(r.tokens.map(\.text), ["It", "costs", "45", "today"])
        XCTAssertEqual(r.timings[2], WordTiming(token: 2, start: 0.6, end: 1.5))
        XCTAssertEqual(r.timings[3], WordTiming(token: 3, start: 1.5, end: 2.0))
    }

    func testDateExpansion() {
        let r = run("On 21 October we go", spoken: [w("on", 0, 0.2), w("twenty", 0.2, 0.5), w("first", 0.5, 0.8), w("of", 0.8, 0.9), w("october", 0.9, 1.4), w("we", 1.4, 1.6), w("go", 1.6, 1.9)], duration: 1.9)
        XCTAssertEqual(r.timings.map(\.start), [0, 0.2, 0.9, 1.4, 1.6])
        XCTAssertEqual(r.timings[1].end, 0.8)
        // "of" has no source token; the tokens keep their own words' times, the gap is not shared out
        XCTAssertEqual(r.timings[2].start, 0.9)
    }

    func testDroppedWordSharesTheGap() {
        let r = run("one two three four", spoken: [w("one", 0, 0.4), w("two", 0.4, 0.8), w("four", 1.0, 1.4)], duration: 1.4)
        XCTAssertEqual(r.timings[2].start, 0.8, accuracy: 1e-12)
        XCTAssertEqual(r.timings[2].end, 1.0, accuracy: 1e-12)
        assertInvariants(r.timings, tokens: 4, offset: 0, duration: 1.4)
        // two dropped words share it by character length ("a" 1 : "abcd" 4)
        let s = run("one a abcd four", spoken: [w("one", 0, 1), w("four", 6, 7)], duration: 7)
        XCTAssertEqual(s.timings[1].start, 1, accuracy: 1e-12)
        XCTAssertEqual(s.timings[1].end, 2, accuracy: 1e-12)
        XCTAssertEqual(s.timings[2].end, 6, accuracy: 1e-12)
    }

    func testDroppedWordWithNoGapGetsAZeroLengthSentinel() {
        let r = run("one two three four", spoken: [w("one", 0, 0.4), w("two", 0.4, 0.8), w("four", 0.8, 1.4)], duration: 1.4)
        XCTAssertEqual(r.timings[2].start, r.timings[2].end)
        XCTAssertEqual(r.timings[2].start, 0.8)
        assertInvariants(r.timings, tokens: 4, offset: 0, duration: 1.4)
        // and index(at:) never lands on it
        XCTAssertEqual(Timeline.index(at: 0.8, in: r.timings), 3)
        XCTAssertEqual(Timeline.index(at: 0.79, in: r.timings), 1)
    }

    func testLeadingAndTrailingUntimedTokens() {
        let r = run("alpha beta gamma delta", spoken: [w("beta", 1, 2), w("gamma", 2, 3)], offset: 5, duration: 4)
        XCTAssertEqual(r.timings[0], WordTiming(token: 0, start: 5, end: 6))
        XCTAssertEqual(r.timings[3], WordTiming(token: 3, start: 8, end: 9))
        assertInvariants(r.timings, tokens: 4, offset: 5, duration: 4)
    }

    func testChunkWithNoSpokenWordsSpreadsByLength() {
        let r = run("aa bbbb", spoken: [], offset: 2, duration: 6)
        XCTAssertEqual(r.timings, [WordTiming(token: 0, start: 2, end: 4), WordTiming(token: 1, start: 4, end: 8)])
        // an engine returning words the aligner cannot place is the same thing
        let s = run("aa bbbb", spoken: [w("zzz", 0, 1)], offset: 2, duration: 6)
        XCTAssertEqual(s.timings, r.timings)
        // and a zero-length chunk is all sentinels
        let z = run("aa bbbb", spoken: [], duration: 0)
        XCTAssertTrue(z.timings.allSatisfy { $0.start == $0.end })
    }

    func testRemovedURLPartsGetSentinels() {
        let source = "See https://example.com/path now"
        let r = run(source, spoken: [w("see", 0, 0.3), w("example", 0.3, 0.8), w("dot", 0.8, 1.0), w("com", 1.0, 1.4), w("now", 1.4, 1.8)], duration: 1.8)
        XCTAssertEqual(r.tokens.map(\.text), ["See", "https", "example", "com", "path", "now"])
        XCTAssertEqual(r.timings[1], WordTiming(token: 1, start: 0.3, end: 0.3))       // https: removed, sentinel after "See"
        XCTAssertEqual(r.timings[2], WordTiming(token: 2, start: 0.3, end: 0.8))
        XCTAssertEqual(r.timings[3], WordTiming(token: 3, start: 1.0, end: 1.4))
        XCTAssertEqual(r.timings[4], WordTiming(token: 4, start: 1.4, end: 1.4))       // path: removed, sentinel
        XCTAssertEqual(r.timings[5], WordTiming(token: 5, start: 1.4, end: 1.8))
        assertInvariants(r.timings, tokens: 6, offset: 0, duration: 1.8)
    }

    func testRemovedTokensDoNotTakeAShareOfAGap() {
        // emoji-free removal: a markdown image between two dropped-word tokens; the image's tokens are sentinels, not shares
        let r = run("one ![alt text](pic.png) two three", spoken: [w("one", 0, 1), w("three", 5, 6)], duration: 6)
        let kinds = r.timings.map { $0.end > $0.start ? "T" : "S" }
        XCTAssertEqual(r.tokens.map(\.text), ["one", "alt", "text", "pic", "png", "two", "three"])
        XCTAssertEqual(kinds, ["T", "S", "S", "S", "S", "T", "T"])
        XCTAssertEqual(r.timings[5].start, 1, accuracy: 1e-12)
        XCTAssertEqual(r.timings[5].end, 5, accuracy: 1e-12)
    }

    func testSharedSpokenWordsAreSplitByLength() {
        let r = run("I love New York today", lexicon: ["New York": "nyc"], spoken: [w("I", 0, 0.2), w("love", 0.2, 0.5), w("nyc", 0.5, 1.2), w("today", 1.2, 1.6)], duration: 1.6)
        XCTAssertEqual(r.speakable.text, "I love nyc today")
        let (n, y) = (r.timings[2], r.timings[3])
        XCTAssertEqual(n.start, 0.5, accuracy: 1e-12)
        XCTAssertEqual(n.end, y.start, accuracy: 1e-12)
        XCTAssertEqual(y.end, 1.2, accuracy: 1e-12)
        XCTAssertEqual(n.end - n.start, 0.7 * 3 / 7, accuracy: 1e-9)   // "New" 3 : "York" 4
        XCTAssertGreaterThan(y.end - y.start, n.end - n.start)
        XCTAssertEqual(r.timings[4], WordTiming(token: 4, start: 1.2, end: 1.6))
        assertInvariants(r.timings, tokens: 5, offset: 0, duration: 1.6)
    }

    func testSystemVoiceRangesAreUsedDirectly() {
        // "Hello world, it's me": the engine reports speakable ranges, with a word the aligner could never place
        let source = "Hello world, it's me"
        let r = run(source, spoken: [w("Hello", 0, 0.5, range: 0..<5), w("world", 0.5, 1.0, range: 6..<11), w("itz", 1.2, 1.5, range: 13..<17), w("me", 1.5, 1.8, range: 18..<20)], duration: 1.8)
        XCTAssertEqual(r.timings.map(\.start), [0, 0.5, 1.2, 1.5])
        // a range in the speakable text of a lexicon word maps back through the source
        let lex = run("Ask Nguyen", lexicon: ["Nguyen": "win"], spoken: [w("Ask", 0, 0.5, range: 0..<3), w("win", 0.5, 1.0, range: 4..<7)], duration: 1)
        XCTAssertEqual(lex.timings[1], WordTiming(token: 1, start: 0.5, end: 1.0))
    }

    func testEngineTimesOutsideTheChunkAreClamped() {
        let r = run("a b", spoken: [w("a", -1, 0.5), w("b", 0.5, 9)], offset: 1, duration: 1)
        assertInvariants(r.timings, tokens: 2, offset: 1, duration: 1)
        XCTAssertEqual(r.timings[1].end, 2)
    }

    func testIndexAt() {
        let t = [WordTiming(token: 0, start: 1, end: 2), WordTiming(token: 1, start: 2, end: 2), WordTiming(token: 2, start: 2.5, end: 3)]
        XCTAssertNil(Timeline.index(at: 0.9, in: t))
        XCTAssertEqual(Timeline.index(at: 1, in: t), 0)
        XCTAssertEqual(Timeline.index(at: 2, in: t), 0)       // the zero-length one is skipped: word 0 stays lit
        XCTAssertEqual(Timeline.index(at: 2.2, in: t), 0)     // a pause keeps the previous word
        XCTAssertEqual(Timeline.index(at: 2.5, in: t), 2)
        XCTAssertEqual(Timeline.index(at: 99, in: t), 2)      // after the end: the last word
        XCTAssertNil(Timeline.index(at: 1, in: []))
        XCTAssertNil(Timeline.index(at: 5, in: [WordTiming(token: 0, start: 1, end: 1)]))
    }

    // MARK: property test

    func testInvariantsHoldOnRandomInput() {
        let pool = ["alpha", "beta", "gamma", "Nguyen", "42", "£45", "50%", "https://example.com/x/y", "john@example.org", "😀", "**bold**",
                    "the", "a", "NASA", "state-of-the-art", "3.5", "21st", "e.g.", "New", "York", "[link](http://a.b/c)", "www.site.org", "- item", "# head"]
        let seps = [" ", " ", " ", ", ", ". ", "\n", "  ", " — "]
        var rng = SplitMix(seed: 2026)
        var checked = 0, sentinels = 0
        for round in 0..<600 {
            var source = ""
            for _ in 0..<Int(rng.next() % 25) { source += pool[Int(rng.next() % UInt64(pool.count))] + seps[Int(rng.next() % UInt64(seps.count))] }
            let length = (source as NSString).length
            let lexicon = round % 3 == 0 ? ["nguyen": "win", "new york": "nyc"] : [:]
            let speakable = Speakable.make(source, range: 0..<length, lexicon: lexicon)
            let tokens = TextKit.tokenize(source)
            // the engine: says each speakable word with random durations and gaps, drops some, gives ranges for some
            var spoken: [SpokenWord] = []
            var clock = 0.0
            let useRanges = round % 2 == 0
            for tok in TextKit.tokenize(speakable.text) where rng.next() % 100 >= 12 {
                clock += rng.unit() < 0.3 ? 0 : rng.unit() * 0.1
                let d = 0.05 + rng.unit() * 0.4
                spoken.append(SpokenWord(text: tok.text, start: clock, end: clock + d, range: useRanges ? tok.range : nil))
                clock += d
            }
            if rng.next() % 10 == 0 { spoken.append(SpokenWord(text: "extra", start: clock, end: clock + 0.1)); clock += 0.1 }
            let duration = rng.next() % 8 == 0 ? clock * 0.5 : clock + rng.unit() * 0.3   // sometimes the chunk is shorter than the words
            let offset = rng.unit() * 20
            let offsetToken = Int(rng.next() % 50)
            let t = Timeline.timings(chunkTokens: tokens, chunkTokenOffset: offsetToken, speakable: speakable, spoken: spoken, offset: offset, chunkDuration: duration)
            assertInvariants(t, tokens: tokens.count, tokenOffset: offsetToken, offset: offset, duration: duration)
            if !tokens.isEmpty && duration > 0 && spoken.isEmpty { XCTAssertTrue(t.contains { $0.end > $0.start } || tokens.allSatisfy { !speakable.covers($0.range) }, "round \(round)") }
            checked += t.count
            sentinels += t.filter { $0.start == $0.end }.count
        }
        print("TIMELINE property: \(checked) timings checked, \(sentinels) sentinels")
        XCTAssertGreaterThan(checked, 3000)
    }

    /// An engine that says every speakable word, with a real duration and gap each: every source token Speakable kept gets
    /// a positive-length timing, every one it removed gets a zero-length sentinel, nothing is left to a guess.
    func testFaithfulEngineLeavesNoGuesses() {
        let pool = ["alpha", "beta", "gamma", "Nguyen", "42", "£45", "50%", "https://example.com/x/y", "john@example.org", "😀", "**bold**",
                    "the", "a", "NASA", "state-of-the-art", "3.5", "21st", "e.g.", "New", "York", "[link](http://a.b/c)", "www.site.org", "R&D", "20°C"]
        let seps = [" ", " ", ", ", ". ", "\n", "  ", " — "]
        var rng = SplitMix(seed: 99)
        var tokensChecked = 0, sentinels = 0
        for round in 0..<400 {
            var source = ""
            for _ in 0..<(1 + Int(rng.next() % 20)) { source += pool[Int(rng.next() % UInt64(pool.count))] + seps[Int(rng.next() % UInt64(seps.count))] }
            let speakable = Speakable.make(source, range: 0..<(source as NSString).length, lexicon: round % 2 == 0 ? ["nguyen": "win", "new york": "nyc"] : [:])
            let tokens = TextKit.tokenize(source)
            var spoken: [SpokenWord] = []
            var clock = 0.0
            for tok in TextKit.tokenize(speakable.text) {
                clock += 0.01 + rng.unit() * 0.1
                let d = 0.05 + rng.unit() * 0.4
                spoken.append(SpokenWord(text: tok.text, start: clock, end: clock + d, range: round % 3 == 0 ? tok.range : nil))
                clock += d
            }
            let t = Timeline.timings(chunkTokens: tokens, chunkTokenOffset: 0, speakable: speakable, spoken: spoken, offset: 0, chunkDuration: clock + 0.2)
            for (token, timing) in zip(tokens, t) {
                if speakable.covers(token.range) {
                    XCTAssertGreaterThan(timing.end, timing.start, "\(token.text) in \(source.debugDescription) -> \(speakable.text.debugDescription)")
                } else {
                    XCTAssertEqual(timing.start, timing.end, "\(token.text) in \(source.debugDescription)")
                    sentinels += 1
                }
                tokensChecked += 1
            }
        }
        print("FAITHFUL: \(tokensChecked) tokens, \(sentinels) removed-token sentinels")
    }
}
