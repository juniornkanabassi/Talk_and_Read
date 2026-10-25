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

    func testLinkTargetsWithSpacesOrAngleBracketsAreDropped() {
        let spaced = "See [MEMORY.md](/Users/junior/Documents/JuniorOS/01 About Me/MEMORY.md) now."
        let sp = make(spaced)
        XCTAssertEqual(sp.text, "See MEMORY.md now.")
        XCTAssertEqual(origin(sp, "MEMORY.md", spaced), "MEMORY.md")
        XCTAssertFalse(sp.covers((spaced as NSString).range(of: "About Me").toRange()))
        XCTAssertEqual(make("Read [the guide](<02 Projects/Talk & Read/guide.md>) first.").text, "Read the guide first.")
        XCTAssertEqual(make("[plan](/Users/j/01%20About%20Me/plan.md)").text, "plan")
        XCTAssertEqual(make("[Law](https://en.wikipedia.org/wiki/Law_(UK)) here").text, "Law here")
        XCTAssertEqual(make("[a](x \"title\") b").text, "a b")
        // ordinary brackets are prose: no "](" join, or the target would cross a line
        XCTAssertEqual(make("He [sic] (again) said").text, "He [sic] (again) said")
        XCTAssertEqual(make("[note](see\nbelow)").text, "[note](see. below)")
        // the first ")" ends the target, so prose after a link survives
        XCTAssertEqual(make("[x](a/b c.md) and (c) d").text, "x and (c) d")
        // spaces only in a path- or address-like target: bracketed prose before parentheses stays
        XCTAssertEqual(make("options [A](which is best) or [B]").text, "options [A](which is best) or [B]")
        XCTAssertEqual(make("options [A](which is best.) or [B]").text, "options [A](which is best.) or [B]")
        XCTAssertEqual(make("[x](and/or something) y").text, "[x](and/or something) y")
        XCTAssertEqual(make("[notes](../02 Projects/notes) y").text, "notes y")
        XCTAssertEqual(make("[part](Talk & Read guide.md#setup) y").text, "part y")
        XCTAssertEqual(make("[A](x) or [B](y)").text, "A or B")
    }

    func testFilePathsAreSpokenAsTheirFileName() {
        let s = "Saved to /Users/junior/Documents/notes/plan.md, then ~/Documents/JuniorOS/AGENTS.md."
        let sp = make(s)
        XCTAssertEqual(sp.text, "Saved to plan.md, then AGENTS.md.")
        // the name stands for the whole path, so the highlight covers what is on screen
        XCTAssertEqual(origin(sp, "plan.md", s), "/Users/junior/Documents/notes/plan.md")
        XCTAssertEqual(origin(sp, "AGENTS.md", s), "~/Documents/JuniorOS/AGENTS.md")
        XCTAssertEqual(make("Open file:///Users/j/01%20About%20Me/Talk%20%26%20Read.md now").text, "Open Talk & Read.md now")
        XCTAssertEqual(make("In /mnt/project-files/brief.pdf").text, "In brief.pdf")
        XCTAssertEqual(make("The folder /Users/j/Talk/ is new").text, "The folder Talk is new")   // no stray "/"
        XCTAssertEqual(make("See /Users/j/Law_(UK) now").text, "See Law_(UK) now")
        XCTAssertEqual(make("In /Users/j/O'Brien/report.md now").text, "In report.md now")   // Codex round 7
        XCTAssertEqual(make("('/Users/j/a/b.md')").text, "('b.md')")
        XCTAssertEqual(make("(see /Users/j/a/b.md), then").text, "(see b.md), then")
        XCTAssertEqual(make("Kept in /a/b/report.final.pdf.").text, "Kept in report.final.pdf.")
        XCTAssertEqual(make("Open ~/notes.md and file:///notes.md").text, "Open notes.md and notes.md")
        XCTAssertEqual(make("The `/a/b/report.pdf` file").text, "The report.pdf file")   // bare and backticked agree
        XCTAssertEqual(make("A /notes.md file").text, "A /notes.md file")   // one component and no root: not sure
        // not file paths: no known root and no file name, or a command line in backticks
        for kept in ["/r/soccer", "/api/v1/users", "/dev/null", "cd /usr/local/bin", "his/her", "/a/b/c"] {
            XCTAssertEqual(make(kept).text, kept)
        }
        XCTAssertEqual(make("Run `/bin/ls -la /tmp/x` now").text, "Run /bin/ls -la /tmp/x now")
        XCTAssertEqual(make("Run `/usr/bin/env python3 a.py`").text, "Run /usr/bin/env python3 a.py")
        XCTAssertEqual(make("Run `/Users/j/venv/bin/python scripts/train.py` now.").text, "Run /Users/j/venv/bin/python scripts/train.py now.")
        XCTAssertEqual(make("Run `~/tools/node app/server.js` now.").text, "Run ~/tools/node app/server.js now.")
        XCTAssertEqual(make("See /Users/j/Source/App.swift:42 for it").text, "See App.swift for it")
        XCTAssertEqual(make("The file `/Users/j/02 Projects/Talk & Read/guide.md` is new").text, "The file guide.md is new")
        XCTAssertEqual(make("([/Users/j/a/notes.md](/Users/j/a/notes.md))").text, "(notes.md)")
        // not paths: no leading "/" or "~/" at a word's start, or a single component
        for kept in ["and/or", "km/h", "24/7", "14/11/2027", "1/2 cup", "w/o sugar", "a /s joke", "http://x.io/a/b"] {
            XCTAssertFalse(make(kept).text.isEmpty, kept)
            if !kept.hasPrefix("http") { XCTAssertEqual(make(kept).text, kept) }
        }
        XCTAssertEqual(make("src/app/main.swift stays").text, "src/app/main.swift stays")
    }

    /// TR-006: a read speaks chunk by chunk, and the chunker cuts a long sentence at spaces, so a link or path it cuts
    /// through must be read whole by the chunk it starts in and skipped by the next.
    func testLinksAndPathsAcrossChunks() {
        func read(_ s: String) -> String {
            TextKit.chunks(s, tokens: TextKit.tokenize(s)).map { Speakable.make(s, range: $0.range, lexicon: [:]).text }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        XCTAssertEqual(read("See [guide](/Users/j/01 About Me/guide.md) now and then more words here."),
                       "See guide now and then more words here.")
        XCTAssertEqual(read("Saved to /Users/junior/Documents/notes/plan.md, then done."), "Saved to plan.md, then done.")
        let long = "Hello there. " + String(repeating: "word ", count: 50)
            + "[the long link label](/Users/junior.nkanabassi/Documents/JuniorOS/02 Projects/Development/Talk & Read/Outputs/guide.md) end."
        XCTAssertEqual(read(long), "Hello there. " + String(repeating: "word ", count: 50) + "the long link label end.")
        let code = String(repeating: "word ", count: 30) + "the file `/Users/j/02 Projects/Talk & Read/a long folder name/guide.md` is new."
        XCTAssertEqual(read(code), String(repeating: "word ", count: 30) + "the file guide.md is new.")
        // a sentence end inside a link label, and a long bare path, start no chunk (Codex round 3)
        XCTAssertEqual(read("See [First sentence. Second sentence](https://example.com) now."), "See First sentence. Second sentence now.")
        let path = "/Users/" + String(repeating: "project/", count: 20) + "notes.md"
        XCTAssertEqual(read("Saved at " + path + " today."), "Saved at notes.md today.")
        // a path longer than any chunk, alone, is one chunk and one name (Codex round 4)
        let alone = "/Users/" + String(repeating: "project/", count: 50) + "notes.md"
        XCTAssertEqual(read(alone), "notes.md")
        // a link whose target holds balanced brackets is kept whole too (Codex round 5)
        let bracketed = "[guide](/Users/j/Folder_(old)/" + String(repeating: "folder ", count: 50) + "guide.md) end."
        XCTAssertEqual(read(bracketed), "guide end.")
        // a long code span is still cut to chunk size, every word read once (Codex round 5)
        let bigSpan = "`" + String(repeating: "make all ", count: 400) + "`"
        let chunks = TextKit.chunks(bigSpan, tokens: TextKit.tokenize(bigSpan))
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.range.count <= 320 })
        XCTAssertEqual(read(bigSpan).split(separator: " ").count, 800)
        // an ordinary code span the opening chunk's limit falls in is read once (Codex round 2)
        let span = "Run " + "`" + String(repeating: "make all ", count: 25) + "`" + " then stop."
        XCTAssertEqual(read(span), "Run " + String(repeating: "make all ", count: 25) + "then stop.")
    }

    func testFencedCodeIsReadAsWritten() {
        XCTAssertEqual(make("Run:\n```sh\ncat /Users/j/notes.md\n```\nDone.").text, "Run: cat /Users/j/notes.md. Done.")
        // chunk by chunk too: the chunk after the fence line knows it is inside the block (Codex round 6)
        let s = "```sh\ncat /Users/j/notes.md\n```\nDone."
        let read = TextKit.chunks(s, tokens: TextKit.tokenize(s)).map { Speakable.make(s, range: $0.range, lexicon: [:]).text }
            .filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertEqual(read, "cat /Users/j/notes.md. Done.")
        // a fence counts only at a line's start, in a scan and when a chunk works out its state
        XCTAssertEqual(make("Text  ```sh and /Users/j/a.md").text, "Text sh and a.md")   // no fence mid-line: the path is still a name
        // a single-component ~/ path is kept whole by the chunker too: its name is said once
        let home = "~/" + String(repeating: "ab-", count: 50) + "notes.md"
        let homeRead = TextKit.chunks(home, tokens: TextKit.tokenize(home)).map { Speakable.make(home, range: $0.range, lexicon: [:]).text }.joined()
        XCTAssertEqual(homeRead, String(repeating: "ab-", count: 50) + "notes.md")
    }

    /// A path too long to keep whole is read as written, never as a cut-short name or twice (Codex round 6).
    func testAPathLongerThanTheContextIsReadAsWritten() {
        let path = "/Users/" + String(repeating: "project/", count: 100) + "notes.md"
        let read = TextKit.chunks(path, tokens: TextKit.tokenize(path)).map { Speakable.make(path, range: $0.range, lexicon: [:]).text }
            .joined(separator: "")
        XCTAssertEqual(read.components(separatedBy: "notes.md").count, 2)
        XCTAssertEqual(read.components(separatedBy: "project").count, 101)
    }

    /// An unclosed "[" on a long line costs linear time, not a rescan from every bracket (Codex round 5).
    /// Fence state for every chunk of a long read is a lookup, not a rescan of the text before it (Codex, blocking pass).
    func testFenceStateStaysFastOverALongRead() {
        let s = String(repeating: "A plain sentence with no code at all in it. ", count: 20_000)
        let start = Date()
        let chunks = TextKit.chunks(s, tokens: TextKit.tokenize(s))
        for c in chunks { _ = Speakable.make(s, range: c.range, lexicon: [:]) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        XCTAssertGreaterThan(chunks.count, 2000)
    }

    func testManyOpenBracketsStayFast() {
        let start = Date()   // a path then 50,000 closing brackets: one pass (Codex round 7)
        _ = make("/Users/j/notes.md" + String(repeating: ")", count: 50_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        for s in [String(repeating: "[word ", count: 20_000), String(repeating: "[x](word ", count: 20_000) + ")"] {
            let start = Date()
            _ = TextKit.chunks(s, tokens: TextKit.tokenize(s))
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    /// Lines that each open with a link or path still make chunks of normal size: a chunk may start right at a
    /// construct, only never inside one (fresh triage of 6039f0d: such a list was one chunk of thousands of characters).
    func testListsOfLinksAndPathsKeepChunksSmall() {
        let lists = [String(repeating: "- [Intro](#intro)\n", count: 100),
                     (1...100).map { "/Users/j/notes/file\($0).md\n" }.joined(),
                     (1...100).map { "`/Users/j/02 Projects/file\($0).md`\n" }.joined()]
        for s in lists {
            let tokens = TextKit.tokenize(s)
            let chunks = TextKit.chunks(s, tokens: tokens)
            XCTAssertTrue(chunks.allSatisfy { $0.range.count <= 320 }, "longest \(chunks.map(\.range.count).max() ?? 0)")
            // every token in exactly one chunk, in order, and the chunks' speech is the whole read's
            XCTAssertEqual(chunks.flatMap { Array($0.tokens) }, Array(tokens.indices))
            func words(_ t: String) -> [String] { TextKit.tokenize(t).map(\.text) }   // a chunk's end drops its full stop
            XCTAssertEqual(chunks.flatMap { words(Speakable.make(s, range: $0.range, lexicon: [:]).text) },
                           words(Speakable.make(s, range: 0..<(s as NSString).length, lexicon: [:]).text))
        }
    }

    /// A read that starts inside a link (a click in the reader, a saved place) reads the link whole (Codex round 2).
    func testAReadStartingInsideALink() {
        let s = "[the guide](/Users/j/guide.md) now."
        let at = (s as NSString).range(of: "guide").location
        XCTAssertEqual(Speakable.make(s, range: at..<(s as NSString).length, lexicon: [:]).text, "the guide now.")
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

    // MARK: Skipping (Speechify's "skip citations" and "skip headers and footers")

    private func cited(_ source: String) -> String {
        Speakable.make(source, range: 0..<(source as NSString).length, lexicon: [:], skipCitations: true).text
    }

    func testCitationMarksAreNotSpokenWhenSkipped() {
        XCTAssertEqual(cited("The contract was void[12] from the start."), "The contract was void from the start.")
        XCTAssertEqual(cited("See the cases.[3, 5–7][9a] Then"), "See the cases. Then")
        XCTAssertEqual(cited("It was settled law.[citation needed]"), "It was settled law.")
        XCTAssertEqual(cited("There was no consideration.12 The court agreed."), "There was no consideration. The court agreed.")
        XCTAssertEqual(cited("As Smith¹, Jones² said, it was argued.²³ Then"), "As Smith, Jones said, it was argued. Then")
        XCTAssertEqual(cited("He called it “a nullity”.4 Then"), "He called it “a nullity”. Then")
        XCTAssertEqual(cited("The point was made.7\nNext line"), "The point was made. Next line")
        // Kept: paragraph references, pinpoints, section and article numbers, stats, decimals, thousands, maths, years.
        XCTAssertEqual(cited("[23] The claimant appealed."), "[23] The claimant appealed.")
        XCTAssertEqual(cited("Per Lord Reed at [45] and paras [12]–[15]."), "Per Lord Reed at [45] and paras [12]–[15].")
        XCTAssertEqual(cited("See [2024] EWCA Civ 12 at [23]."), "See [2024] EWCA Civ 12 at [23].")
        XCTAssertEqual(cited("Under s.12 The Act, para.4 Then arts.8 And regs.4 Apply."), "Under s.12 The Act, para.4 Then arts.8 And regs.4 Apply.")
        XCTAssertEqual(cited("Goals:12 Shots:14 and the result.3 points"), "Goals:12 Shots:14 and the result.3 points")
        XCTAssertEqual(cited("It cost 3.5 or 1,000 or 12:30."), "It cost 3.5 or 1,000 or 12:30.")
        XCTAssertEqual(cited("The area is 4 m² and x³."), "The area is 4 m² and x³.")
        XCTAssertEqual(cited("He said:\"12 men\" came."), "He said:\"12 men\" came.")
        XCTAssertEqual(cited("A [link](https://example.com) stays."), "A link stays.")
        // Off: unchanged.
        XCTAssertEqual(make("The contract was void[12].").text, "The contract was void[12].")
    }

    func testAPageBreakWithItsFurnitureSkippedJoinsTheSentence() {
        let s = "the claimant was\n12\n\nJournal of Law\nentitled to it."   // "12" 17..<19, "Journal of Law" 21..<35
        let sp = Speakable.make(s, range: 0..<(s as NSString).length, lexicon: [:], skip: [17..<19, 21..<35])
        XCTAssertEqual(sp.text, "the claimant was entitled to it.")
        XCTAssertEqual(make("the claimant was\nentitled").text, "the claimant was. entitled", "an ordinary line break still pauses")
    }

    func testSkippedRangesAreNotSpokenAndNotCovered() {
        let s = "Header\nBody text here.\nFooter"   // Header 0..<6, Body 7..<22, Footer 23..<29
        let sp = Speakable.make(s, range: 0..<29, lexicon: [:], skip: [23..<29, 0..<6])
        XCTAssertEqual(sp.text, "Body text here.")
        XCTAssertFalse(sp.covers(0..<6))
        XCTAssertFalse(sp.covers(23..<29))
        XCTAssertTrue(sp.covers(7..<11))
        XCTAssertEqual(origin(sp, "Body", s), "Body")
        // A range that starts before the chunk is clipped to it.
        XCTAssertEqual(Speakable.make(s, range: 7..<29, lexicon: [:], skip: [3..<12]).text, "text here. Footer")
    }

    func testNoMatchReachesIntoSkippedText() {
        // "York" is a skipped line: the "New York" key must not swallow it, nor give it a spoken, timed source.
        let s = "New\nYork\nTail."
        let sp = Speakable.make(s, range: 0..<14, lexicon: ["New York": "nyc"], skip: [4..<8])
        XCTAssertFalse(sp.text.contains("nyc"), sp.text)
        XCTAssertFalse(sp.covers(4..<8))
    }

    func testReferenceListsAndAnnotations() {
        XCTAssertEqual(cited("See paras [12],[13] for the rule."), "See paras [12],[13] for the rule.")
        XCTAssertEqual(cited("The claim is disputed. [citation needed] Then"), "The claim is disputed. Then")
    }

    func testAChunkEndIsNotALineEnd() {
        // The chunk ends after "scored;12 "; the real next word is lowercase, so 12 is a number, not a footnote.
        let s = "They scored;12 points tonight."
        let cut = (s as NSString).range(of: "points").location
        XCTAssertEqual(Speakable.make(s, range: 0..<cut, lexicon: [:], skipCitations: true).text, "They scored;12")
        XCTAssertEqual(Speakable.make(s, range: 0..<(s as NSString).length, lexicon: [:], skipCitations: true).text, s)
        XCTAssertEqual(cited("There was no consideration.12"), "There was no consideration.")
    }

    func testLinkedMarksAndALongGapAfterAChunk() {
        XCTAssertEqual(cited("It was Law.[12](#note) Then"), "It was Law. Then")
        XCTAssertEqual(cited("Claim [citation needed](https://example.com) here."), "Claim here.")
        XCTAssertEqual(cited("A [link](https://example.com) and [3](#n) stay."), "A link and 3 stay.")
        // The look-ahead runs out in spaces: no crash, and too little evidence to drop the 12.
        let s = "void.12" + String(repeating: " ", count: 700) + "Next"
        XCTAssertEqual(Speakable.make(s, range: 0..<7, lexicon: [:], skipCitations: true).text, "void.12")
    }

    func testMarksAfterQuestionAndExclamationMarks() {
        XCTAssertEqual(cited("Was it lawful?[12] Then"), "Was it lawful? Then")
        XCTAssertEqual(cited("What a goal!¹ Then"), "What a goal! Then")
        XCTAssertEqual(cited("Was it lawful? [12] Then"), "Was it lawful? [12] Then")
    }

    func testMarksAtAChunkStartAreJudgedInContext() {
        // The chunker splits at "consideration." so "12 The…" opens the next chunk; the mark is still a footnote.
        let s = "There was no consideration.12 The court agreed. It was void[3] then."
        let ns = s as NSString
        func from(_ needle: String) -> String {
            Speakable.make(s, range: ns.range(of: needle).location..<ns.length, lexicon: [:], skipCitations: true).text
        }
        XCTAssertEqual(from("12 The"), "The court agreed. It was void then.")
        XCTAssertEqual(from("[3] then"), "then.")
        // A chunk that opens its line still keeps a line-leading paragraph number.
        let j = "Intro.\n[23] The claimant appealed."
        XCTAssertEqual(Speakable.make(j, range: 7..<(j as NSString).length, lexicon: [:], skipCitations: true).text, "[23] The claimant appealed.")
    }
}

private extension NSRange {
    func toRange() -> Range<Int> { location..<(location + length) }
}
