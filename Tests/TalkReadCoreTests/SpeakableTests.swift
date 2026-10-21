import XCTest
@testable import TalkReadCore

final class SpeakableTests: XCTestCase {
    private func make(_ source: String, lexicon: [String: String] = [:]) -> Speakable {
        Speakable.make(source, range: 0..<(source as NSString).length, lexicon: lexicon)
    }

    /// The source text that the `occurrence`th (0-based) appearance of `word` in the speakable text came from.
    private func origin(_ sp: Speakable, _ word: String, _ source: String, occurrence: Int = 0) -> String {
        let t = sp.text as NSString
        var r = NSRange(location: 0, length: 0), from = 0
        for _ in 0...occurrence {
            r = t.range(of: word, range: NSRange(location: from, length: t.length - from))
            XCTAssertNotEqual(r.location, NSNotFound, "\(word) not found in \(sp.text)")
            if r.location == NSNotFound { return "" }
            from = r.location + r.length
        }
        let sr = sp.sourceRange(r.location..<(r.location + r.length))
        return (source as NSString).substring(with: NSRange(location: sr.lowerBound, length: sr.count))
    }

    func testPlainTextIsUnchangedWithIdentityMap() {
        let s = "Plain words, punctuation and £5 stay."
        let sp = make(s)
        XCTAssertEqual(sp.text, s)
        XCTAssertEqual(sp.sourceRange(6..<11), 6..<11)
        XCTAssertEqual(origin(sp, "£5", s), "£5")
        XCTAssertEqual(make("").text, "")
        XCTAssertEqual(make("").sourceRange(0..<0), 0..<0)
        XCTAssertEqual(Speakable(text: "abc").sourceRange(1..<3), 1..<3)
    }

    func testLexiconSubstitutionMapsBackToTheSourceWord() {
        let s = "Ask Nguyen about it; nguyen agrees, NGUYEN too."
        let sp = make(s, lexicon: ["Nguyen": "win"])
        XCTAssertEqual(sp.text, "Ask win about it; win agrees, win too.")
        XCTAssertEqual(origin(sp, "win", s, occurrence: 0), "Nguyen")
        XCTAssertEqual(origin(sp, "win", s, occurrence: 1), "nguyen")
        XCTAssertEqual(origin(sp, "win", s, occurrence: 2), "NGUYEN")
        // any sub-range of the replacement maps to the whole source word
        let at = (sp.text as NSString).range(of: "win").location
        XCTAssertEqual(sp.sourceRange((at + 1)..<(at + 2)), 4..<10)
        // whole words only
        XCTAssertEqual(make("Nguyens and Nguyen2", lexicon: ["Nguyen": "win"]).text, "Nguyens and Nguyen2")
    }

    func testLexiconLongestKeyFirstAndMultiWordKeys() {
        let lex = ["New York": "nyc", "New": "fresh", "New York City": "the big apple"]
        let s = "New York City, New York and New Jersey, new  \nyork!"
        let sp = make(s, lexicon: lex)
        XCTAssertEqual(sp.text, "the big apple, nyc and fresh Jersey, nyc!")
        XCTAssertEqual(origin(sp, "the big apple", s), "New York City")
        XCTAssertEqual(origin(sp, "nyc", s, occurrence: 1), "new  \nyork")
    }

    func testURLsAreSpokenAsHostWords() {
        let s = "See https://www.example.com/a/b?x=1#top now. Or HTTP://docs.example.co.uk:8080/x, or http://user:pw@a.io/p."
        let sp = make(s)
        XCTAssertEqual(sp.text, "See www dot example dot com now. Or docs dot example dot co dot uk, or a dot io.")
        XCTAssertEqual(origin(sp, "www dot example dot com", s), "www.example.com")
        XCTAssertEqual(origin(sp, "example", s, occurrence: 0), "example")
        XCTAssertEqual(origin(sp, "dot", s, occurrence: 0), ".")
        XCTAssertEqual(origin(sp, "docs dot example dot co dot uk", s), "docs.example.co.uk")
        XCTAssertEqual(origin(sp, "a dot io", s), "a.io")
        // the scheme, userinfo, port and path are removed: not covered, so Timeline gives their tokens sentinels
        let ns = s as NSString
        for gone in ["https", "/a/b?x=1#top", "8080", "pw", "/p"] { XCTAssertFalse(sp.covers(ns.range(of: gone).toRange()), gone) }
        for kept in ["example", "now", "docs", "a.io"] { XCTAssertTrue(sp.covers(ns.range(of: kept).toRange()), kept) }
    }

    func testBareWWWAndEmail() {
        let s = "Visit www.bbc.co.uk/news, or mail john.smith@example.org."
        let sp = make(s)
        XCTAssertEqual(sp.text, "Visit www dot bbc dot co dot uk, or mail john dot smith at example dot org.")
        XCTAssertEqual(origin(sp, "www dot bbc dot co dot uk", s), "www.bbc.co.uk")
        XCTAssertEqual(origin(sp, "at", s, occurrence: 0), "@")
        XCTAssertEqual(origin(sp, "john dot smith at example dot org", s), "john.smith@example.org")
        XCTAssertEqual(origin(sp, "smith", s), "smith")
    }

    func testMarkdownNoiseIsDropped() {
        let s = "# Title\n\n> quoted **bold** and __under__ `code` [link text](https://x.com/page \"t\") ![pic](a.png) end"
        let sp = make(s)
        XCTAssertEqual(sp.text, "Title. quoted bold and under code link text end")
        XCTAssertEqual(origin(sp, "Title", s), "Title")
        XCTAssertEqual(origin(sp, "bold", s), "bold")
        XCTAssertEqual(origin(sp, "link text", s), "link text")
        XCTAssertEqual(origin(sp, "end", s), "end")
        XCTAssertFalse(sp.covers((s as NSString).range(of: "a.png").toRange()))
        XCTAssertFalse(sp.covers((s as NSString).range(of: "pic").toRange()))
        // markup inside link text is handled too
        XCTAssertEqual(make("[**big** news](u)").text, "big news")
    }

    func testListItemsGetAPause() {
        XCTAssertEqual(make("- one\n- two\n* three.\n+ four\n\n1. five\n2) six").text, "one. two. three. four. 1. five. 2) six")
        XCTAssertEqual(make("Intro:\n- first\n- second").text, "Intro: first. second")
        XCTAssertEqual(make("Done.\nNext line\r\nthird").text, "Done. Next line. third")
        XCTAssertEqual(make("Quote said \"yes.\"\nthen").text, "Quote said \"yes.\" then")
        let s = "- one\n- two"
        let sp = make(s)
        XCTAssertEqual(origin(sp, "one", s), "one")
        XCTAssertEqual(origin(sp, "two", s), "two")
        // the inserted full stop maps to the newline it replaces
        XCTAssertEqual(origin(sp, ".", s), "\n")
    }

    func testSymbols() {
        let s = "R&D at 50% and 20°C, 70°F, 5° tilt, ~5 miles, ~ £3, 100% sure, a~b. Cost £5 / day"
        let sp = make(s)
        XCTAssertEqual(sp.text, "R and D at 50 percent and 20 degrees Celsius, 70 degrees Fahrenheit, 5 degrees tilt, about 5 miles, about £3, 100 percent sure, a~b. Cost £5 / day")
        XCTAssertEqual(origin(sp, "and", s, occurrence: 0), "&")
        XCTAssertEqual(origin(sp, "percent", s, occurrence: 0), "%")
        XCTAssertEqual(origin(sp, "degrees Celsius", s), "°C")
        XCTAssertEqual(origin(sp, "degrees Fahrenheit", s), "°F")
        XCTAssertEqual(origin(sp, "about", s, occurrence: 0), "~")
        XCTAssertEqual(origin(sp, "about", s, occurrence: 1), "~")
        XCTAssertEqual(origin(sp, "100", s), "100")
        XCTAssertEqual(origin(sp, "percent", s, occurrence: 1), "%")
    }

    func testEmojiAndPictographsAreRemoved() {
        let s = "Hello 😀 world 👍🏽 ❤️ 🇬🇧 done ✨"
        let sp = make(s)
        XCTAssertEqual(sp.text, "Hello world done")
        XCTAssertEqual(origin(sp, "world", s), "world")
        XCTAssertFalse(sp.covers((s as NSString).range(of: "😀").toRange()))
        // digits, the copyright sign and ordinary symbols stay
        XCTAssertEqual(make("1 © ™ # *").text, "1 © ™ # *")
    }

    func testWhitespaceCollapses() {
        let s = "a   b\t\tc \u{00A0} d"
        let sp = make(s)
        XCTAssertEqual(sp.text, "a b c d")
        XCTAssertEqual(origin(sp, "c", s), "c")
        XCTAssertEqual(origin(sp, "d", s), "d")
        XCTAssertEqual(make("   padded   ").text, "padded")
        // a collapsed gap maps to everything it replaced
        XCTAssertEqual(sp.sourceRange(1..<2), 1..<4)
    }

    func testRepeatedReplacementsInOneString() {
        let s = "Nguyen met Nguyen at 50% of 50% and www.a.com www.b.com"
        let sp = make(s, lexicon: ["nguyen": "win"])
        XCTAssertEqual(sp.text, "win met win at 50 percent of 50 percent and www dot a dot com www dot b dot com")
        XCTAssertEqual(origin(sp, "win", s, occurrence: 1), "Nguyen")
        let second = (sp.text as NSString).range(of: "win", range: NSRange(location: 4, length: sp.text.count - 4))
        XCTAssertEqual(sp.sourceRange(second.location..<second.location + 3), 11..<17)
        XCTAssertEqual(origin(sp, "percent", s, occurrence: 0), "%")
        XCTAssertEqual(origin(sp, "percent", s, occurrence: 1), "%")
        XCTAssertEqual(origin(sp, "www dot a dot com", s), "www.a.com")
        XCTAssertEqual(origin(sp, "www dot b dot com", s), "www.b.com")
        let first = sp.sourceRange(((sp.text as NSString).range(of: "percent")).toRange()), last = sp.sourceRange(((sp.text as NSString).range(of: "percent", options: .backwards)).toRange())
        XCTAssertLessThan(first.upperBound, last.lowerBound + 1)
    }

    func testRangeIsInWholeSourceCoordinates() {
        let s = "Skip this. Nguyen and 50% here. Skip that."
        let ns = s as NSString
        let r = ns.range(of: "Nguyen and 50%")
        let sp = Speakable.make(s, range: r.location..<(r.location + r.length), lexicon: ["Nguyen": "win"])
        XCTAssertEqual(sp.text, "win and 50 percent")
        XCTAssertEqual(sp.sourceRange(0..<3), r.location..<(r.location + 6))
        XCTAssertEqual(origin(sp, "percent", s), "%")
        XCTAssertFalse(sp.covers(0..<5))
        // out-of-bounds ranges are clamped
        XCTAssertEqual(Speakable.make("abc", range: 1..<99, lexicon: [:]).text, "bc")
    }

    func testSurrogatePairsKeepUTF16Offsets() {
        let s = "😀 Nguyen 🎉 and 😀😀 x"
        let sp = make(s, lexicon: ["Nguyen": "win"])
        XCTAssertEqual(sp.text, "win and x")
        XCTAssertEqual(origin(sp, "win", s), "Nguyen")
        XCTAssertEqual(origin(sp, "x", s), "x")
        XCTAssertEqual(sp.sourceRange(0..<3), 3..<9)
    }

    func testChunkSizedAndLargeRangesAreFast() {
        let line = "Visit https://example.com/a?b=1 or mail me@x.org, 50% of Nguyen's **notes** are here.\n"
        let big = String(repeating: line, count: 60)   // ~5,000 characters
        let start = Date()
        let sp = Speakable.make(big, range: 0..<(big as NSString).length, lexicon: ["nguyen": "win"])
        let elapsed = Date().timeIntervalSince(start)
        print("SPEAKABLE 5k chars: \(Int(elapsed * 1000)) ms")
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertTrue(sp.text.hasPrefix("Visit example dot com or mail me at x dot org, 50 percent of win's notes are here. Visit"))
    }

    func testSourceRangeEdgeCases() {
        let s = "a Nguyen b"
        let sp = make(s, lexicon: ["Nguyen": "win"])
        XCTAssertEqual(sp.text, "a win b")
        XCTAssertEqual(sp.sourceRange(2..<2), 2..<2)          // empty -> its position
        XCTAssertEqual(sp.sourceRange(0..<99), 0..<10)         // clamped
        XCTAssertEqual(sp.sourceRange(5..<8), 8..<10)          // " b"
        XCTAssertEqual(sp.sourceRange(0..<7), 0..<10)
    }
}

private extension NSRange {
    func toRange() -> Range<Int> { location..<(location + length) }
}
