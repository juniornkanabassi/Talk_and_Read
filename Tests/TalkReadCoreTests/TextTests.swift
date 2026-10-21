import XCTest
@testable import TalkReadCore

final class TextTests: XCTestCase {
    func testTokenizeWordsRangesAndApostrophes() {
        let tokens = TextKit.tokenize("Hello, world. It’s Alice's 3 pm!")
        XCTAssertEqual(tokens.map(\.text), ["Hello", "world", "It’s", "Alice's", "3", "pm"])
        XCTAssertEqual(tokens.map(\.sentence), [0, 0, 1, 1, 1, 1])
        XCTAssertEqual(tokens[1].range, 7..<12)
    }

    func testTokenizeUsesUTF16Ranges() {
        let text = "😀 emoji then word"
        let tokens = TextKit.tokenize(text)
        let ns = text as NSString
        XCTAssertEqual(tokens.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }, tokens.map(\.text))
        XCTAssertEqual(tokens[0].range.lowerBound, 3)
    }

    func testSentenceStarts() {
        func sentences(_ s: String) -> [Int] { TextKit.tokenize(s).map(\.sentence) }
        XCTAssertEqual(sentences("one two\nthree"), [0, 0, 1])
        XCTAssertEqual(sentences("a! b? c. d"), [0, 1, 2, 3])
        XCTAssertEqual(sentences("apples • pears • plums"), [0, 1, 2])
        XCTAssertEqual(sentences("- first item\n- second item"), [0, 0, 1, 1])
        XCTAssertEqual(sentences("* first\n* second"), [0, 1])
        // A list number's dot is a marker: "1" belongs to its item, not to a sentence of its own.
        XCTAssertEqual(sentences("1. Repair the wall.\n2. Approve it."), [0, 0, 0, 0, 1, 1, 1])
        XCTAssertEqual(sentences("It cost 3. Then 4"), [0, 0, 0, 1, 1])
    }

    // MARK: chunks

    private func text(of chunk: Chunk, in s: String) -> String { (s as NSString).substring(with: NSRange(location: chunk.range.lowerBound, length: chunk.range.count)) }

    /// A chunk begins at its first token or at that token's prefix: no whitespace between, never before the previous token.
    private func assertBegins(_ c: Chunk, _ tokens: [Token], in s: String, file: StaticString = #filePath, line: UInt = #line) {
        let i = c.tokens.lowerBound, token = tokens[i].range
        XCTAssertLessThanOrEqual(c.range.lowerBound, token.lowerBound, file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.range.lowerBound, i > 0 ? tokens[i - 1].range.upperBound : 0, file: file, line: line)
        let prefix = (s as NSString).substring(with: NSRange(location: c.range.lowerBound, length: token.lowerBound - c.range.lowerBound))
        XCTAssertFalse(prefix.contains(where: \.isWhitespace), "prefix \(prefix.debugDescription)", file: file, line: line)
    }

    private func assertWellFormed(_ chunks: [Chunk], _ tokens: [Token], _ s: String, from start: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        guard let first = chunks.first, let last = chunks.last else { return }
        // The last chunk runs past the last token only to keep closing punctuation ("?", ".\""), never trailing whitespace.
        XCTAssertGreaterThanOrEqual(last.range.upperBound, tokens.last!.range.upperBound, file: file, line: line)
        XCTAssertLessThanOrEqual(last.range.upperBound - tokens.last!.range.upperBound, 3, file: file, line: line)
        XCTAssertEqual(first.tokens.lowerBound, start, file: file, line: line)
        XCTAssertEqual(last.tokens.upperBound, tokens.count, file: file, line: line)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.range.upperBound, b.range.lowerBound, "ranges are contiguous", file: file, line: line)
            XCTAssertEqual(a.tokens.upperBound, b.tokens.lowerBound, file: file, line: line)
        }
        for c in chunks {   // a token is never split
            XCTAssertFalse(c.tokens.isEmpty, file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.range.upperBound, tokens[c.tokens.upperBound - 1].range.upperBound, file: file, line: line)
            assertBegins(c, tokens, in: s, file: file, line: line)
        }
    }

    func testEmptyAndOutOfRange() {
        XCTAssertEqual(TextKit.chunks("", tokens: []), [])
        XCTAssertEqual(TextKit.chunks("...", tokens: TextKit.tokenize("...")), [])
        let t = TextKit.tokenize("one two")
        XCTAssertEqual(TextKit.chunks("one two", tokens: t, from: 2), [])
        XCTAssertEqual(TextKit.chunks("one two", tokens: t, from: -1), [])
    }

    func testFirstChunkIsTheFirstSentenceAndTheLastKeepsClosingPunctuation() {
        let s = "Hello there. How are you?"
        let t = TextKit.tokenize(s)
        let chunks = TextKit.chunks(s, tokens: t)
        XCTAssertEqual(chunks, [Chunk(range: 0..<13, tokens: 0..<2), Chunk(range: 13..<25, tokens: 2..<5)])
        XCTAssertEqual(text(of: chunks[1], in: s), "How are you?")
        XCTAssertEqual(TextKit.chunks("Just one sentence", tokens: TextKit.tokenize("Just one sentence")), [Chunk(range: 0..<17, tokens: 0..<3)])
    }

    func testWholeSentencesAndTrailingWhitespaceBelongsToEarlierChunk() {
        let sentence = "This sentence has exactly fifty characters in total."   // 52
        let s = (0..<12).map { _ in sentence }.joined(separator: "  \n")
        let t = TextKit.tokenize(s)
        let chunks = TextKit.chunks(s, tokens: t)
        assertWellFormed(chunks, t, s)
        XCTAssertGreaterThan(chunks.count, 2)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.range.count, c == chunks.first ? 120 : 300)
            // whole sentences: a chunk starts on a sentence start
            XCTAssertTrue(c.tokens.lowerBound == 0 || t[c.tokens.lowerBound].sentence != t[c.tokens.lowerBound - 1].sentence)
        }
        XCTAssertEqual(chunks[0].tokens.count, 8)    // the first chunk is the first sentence only: first audio comes fast
        XCTAssertEqual(chunks[1].tokens.count, 40)   // then whole sentences while they fit in 300: five of them (5 x 55 = 275)
        XCTAssertTrue(text(of: chunks[0], in: s).hasSuffix("total.  \n"))
    }

    func testLongFirstSentenceCutsAtClauseBoundary() {
        let s = "When the harbour woke slowly and the first ferry had left carrying passengers, the baker opened up and the whole quay smelled of warm bread. Done."
        let t = TextKit.tokenize(s)
        let chunks = TextKit.chunks(s, tokens: t)
        assertWellFormed(chunks, t, s)
        XCTAssertEqual(text(of: chunks[0], in: s), "When the harbour woke slowly and the first ferry had left carrying passengers, ")
        XCTAssertLessThanOrEqual(chunks[0].range.count, 120)
        XCTAssertEqual(chunks.count, 2)   // the rest of the sentence and "Done." share the second chunk (they fit in 300)
        XCTAssertTrue(text(of: chunks[1], in: s).hasPrefix("the baker"))
    }

    func testClauseMarksAndFallbackToWhitespace() {
        // colon, semicolon, em dash and en dash all count; a bare hyphen does not
        for mark in [";", ":", " —", " –", ","] {
            let s = Array(repeating: "word", count: 15).joined(separator: " ") + mark + " " + Array(repeating: "tail", count: 12).joined(separator: " ")
            let t = TextKit.tokenize(s)
            let c = TextKit.chunks(s, tokens: t, firstMax: 100, max: 300)
            XCTAssertEqual(c.count, 2, mark)
            XCTAssertFalse(text(of: c[0], in: s).contains("tail"), mark)
            XCTAssertTrue(text(of: c[0], in: s).trimmingCharacters(in: .whitespaces).hasSuffix(mark.trimmingCharacters(in: .whitespaces)), "cut after \(mark)")
        }
        // no clause mark anywhere: cut at the last whitespace that fits
        let plain = Array(repeating: "wordy", count: 40).joined(separator: " ")
        let t = TextKit.tokenize(plain)
        let c = TextKit.chunks(plain, tokens: t, firstMax: 50, max: 80)
        assertWellFormed(c, t, plain)
        XCTAssertEqual(c[0].range.count, 48)   // 8 words x 6
        XCTAssertTrue(c.dropFirst().dropLast().allSatisfy { $0.range.count <= 80 })
    }

    func testTinyClauseIsNotWorthACut() {
        let s = "Yes, " + Array(repeating: "wordy", count: 30).joined(separator: " ")
        let t = TextKit.tokenize(s)
        let c = TextKit.chunks(s, tokens: t, firstMax: 100, max: 300)
        XCTAssertGreaterThan(c[0].range.count, 60)   // cut at whitespace, not after "Yes,"
    }

    func testTokenLongerThanMaxStandsAlone() {
        let giant = String(repeating: "a", count: 400)
        let s = "Short start \(giant) end of it."
        let t = TextKit.tokenize(s)
        let c = TextKit.chunks(s, tokens: t, firstMax: 120, max: 300)
        assertWellFormed(c, t, s)
        let alone = c.first { $0.tokens.count == 1 && t[$0.tokens.lowerBound].text == giant }
        XCTAssertNotNil(alone)
        XCTAssertEqual(TextKit.chunks(giant, tokens: TextKit.tokenize(giant)).count, 1)
    }

    func testNeverSplitsATokenOnReadingFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reading.txt")
        let s = try String(contentsOf: url, encoding: .utf8)
        let t = TextKit.tokenize(s)
        XCTAssertGreaterThan(t.count, 100)
        for (firstMax, max) in [(120, 300), (60, 100), (30, 40)] {
            let c = TextKit.chunks(s, tokens: t, firstMax: firstMax, max: max)
            assertWellFormed(c, t, s)
            if c[0].tokens.count > 1 { XCTAssertLessThanOrEqual(c[0].range.count, firstMax) }
            for chunk in c.dropFirst() where chunk.tokens.count > 1 { XCTAssertLessThanOrEqual(chunk.range.count, max) }
        }
    }

    func testStartMidSentence() {
        let s = "Alpha beta gamma delta epsilon. Zeta eta theta. Iota kappa."
        let t = TextKit.tokenize(s)
        XCTAssertEqual(t[2].text, "gamma")
        let c = TextKit.chunks(s, tokens: t, from: 2)
        assertWellFormed(c, t, s, from: 2)
        XCTAssertEqual(c[0].range.lowerBound, t[2].range.lowerBound)
        XCTAssertEqual(c[0].tokens.lowerBound, 2)
        XCTAssertEqual(text(of: c[0], in: s), "gamma delta epsilon. ")   // runs to that sentence's end
        XCTAssertEqual(text(of: c[1], in: s), "Zeta eta theta. Iota kappa.")
        // the original signature is `from: 0`
        XCTAssertEqual(TextKit.chunks(s, tokens: t), TextKit.chunks(s, tokens: t, from: 0))
        // the first chunk is cut short as usual when the rest of the sentence is long
        let long = "Intro words here and then " + Array(repeating: "tail", count: 60).joined(separator: " ") + ". Next."
        let lt = TextKit.tokenize(long)
        let lc = TextKit.chunks(long, tokens: lt, from: 3, firstMax: 50, max: 100)
        assertWellFormed(lc, lt, long, from: 3)
        XCTAssertLessThanOrEqual(lc[0].range.count, 50)
        XCTAssertEqual(lt[lc[0].tokens.lowerBound].text, "and")
    }

    /// Sol #14: a chunk carries its first token's prefix (currency, quote, bracket), at the text start, at every later
    /// chunk start and on a restart; the prefix never pulls in a sentence or clause mark or the previous token.
    func testChunksKeepTheirFirstTokensPrefix() {
        func texts(_ s: String, from start: Int = 0, firstMax: Int = 120) -> [String] {
            let t = TextKit.tokenize(s)
            let c = TextKit.chunks(s, tokens: t, from: start, firstMax: firstMax)
            assertWellFormed(c, t, s, from: start)
            return c.map { text(of: $0, in: s) }
        }
        XCTAssertEqual(texts("£45 was the price. Paid."), ["£45 was the price. ", "Paid."])
        XCTAssertEqual(texts("He paid. £45 was the price."), ["He paid. ", "£45 was the price."])
        XCTAssertEqual(texts("He paid.£45 was the price."), ["He paid.", "£45 was the price."])
        XCTAssertEqual(texts("She left. \"Hello there,\" he said."), ["She left. ", "\"Hello there,\" he said."])
        XCTAssertEqual(texts("Look it up (see the index) now.", from: 3), ["(see the index) now."])
        XCTAssertEqual(texts("A well-known fact.", from: 2), ["known fact."])   // a joiner, not a prefix: no "-known"
        XCTAssertEqual(texts("Yes and/or no.", from: 2), ["or no."])
        // a cut chunk keeps the prefix of the token that opens the next one
        let cut = texts("Prices rose fast and the total was sixty, £45 more than before.", firstMax: 45)
        XCTAssertEqual(cut.count, 2)
        XCTAssertTrue(cut[1].hasPrefix("£45"), cut[1])
    }

    func testLargeInputIsFast() {
        let s = String(repeating: "A reasonably ordinary sentence of about ten words, give or take. ", count: 2000)   // ~130k characters
        let t = TextKit.tokenize(s)
        let start = Date()
        let c = TextKit.chunks(s, tokens: t)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        assertWellFormed(c, t, s)
    }
}
