import XCTest
@testable import TalkReadCore

final class HiddenTextTests: XCTestCase {
    typealias V = HiddenText.Visibility

    // What Claude's projects chat exposes for a selection across two messages (captured live, 25 Oct 2026).
    let heading = "Claude responded: Your Mac won't let me close another session's app for you."
    let body = "Your Mac won't let me close another session's app for you. It's a finished test copy."
    let hint = "\u{FFFC}Quick reactions available — press Tab until focus enters the card, Escape to return.\u{FFFC}\u{FFFC}\u{FFFC}"
    let times = "3m agoSunday, October 25, 2026 at 11:52 AM"

    func testCutsRangesAndKeepsAWordGap() {
        let first = "so leave it open."
        let text = first + hint + times + heading + body
        let u = { (s: String) in s.utf16.count }
        let hidden = [u(first)..<u(first) + u(hint), u(first) + u(hint)..<u(first) + u(hint) + u(times),
                      u(text) - u(body) - u(heading)..<u(text) - u(body)]
        let (out, removed) = HiddenText.cut(text, ranges: hidden)
        XCTAssertEqual(out, first + " " + body)
        XCTAssertEqual(removed, u(hint) + u(times) + u(heading))   // units cut; the space put back is not subtracted
        // no cut, clamped and overlapping ranges
        XCTAssertEqual(HiddenText.cut("abc", ranges: []).text, "abc")
        XCTAssertEqual(HiddenText.cut("abc def", ranges: [3..<4, 2..<3, 5..<99]).text, "ab d")
        XCTAssertEqual(HiddenText.cut("one two", ranges: [3..<4]).text, "one two")
        // a one-unit cut between letters still counts, though a space takes its place
        XCTAssertEqual(HiddenText.cut("a\u{FFFC}b", ranges: [1..<2]).removed, 1)
        // ranges past the end, or reversed by clamping, never trap
        XCTAssertEqual(HiddenText.cut("abc", ranges: [10..<12, -4..<(-1)]).text, "abc")
    }

    func testPlaceFromMarkerDistances() {
        // inside: d1 + d2 is the selection's length
        XCTAssertEqual(HiddenText.place(d1: 10, d2: 90, length: 100, nodeLength: 20)?.range, 10..<30)
        XCTAssertEqual(HiddenText.place(d1: 10, d2: 90, length: 100, nodeLength: 20)?.exact, true)
        // overlapping the end
        XCTAssertEqual(HiddenText.place(d1: 95, d2: 5, length: 100, nodeLength: 20)?.range, 95..<100)
        // starting 5 before the selection, overlapping its start: the node's first 5 units are outside
        let early = HiddenText.place(d1: 5, d2: 105, length: 100, nodeLength: 20)
        XCTAssertEqual(early?.range, 0..<15)
        XCTAssertEqual(early?.skip, 5)
        // wholly before (TR-001: once built 0..<-5 and trapped), wholly after, or unknown: left in
        XCTAssertNil(HiddenText.place(d1: 25, d2: 125, length: 100, nodeLength: 20))
        XCTAssertNil(HiddenText.place(d1: 130, d2: 30, length: 100, nodeLength: 20))
        XCTAssertNil(HiddenText.place(d1: 40, d2: 40, length: 100, nodeLength: 20))
        XCTAssertNil(HiddenText.place(d1: 0, d2: 0, length: 0, nodeLength: 5))
        // a block boundary's line break counted on one side: kept, not exact
        let loose = HiddenText.place(d1: 10, d2: 91, length: 100, nodeLength: 20)
        XCTAssertEqual(loose?.range, 10..<30)
        XCTAssertEqual(loose?.exact, false)
        XCTAssertNil(HiddenText.place(d1: 10, d2: 93, length: 100, nodeLength: 20))
        // an exact overlap with the start wins over a tolerant "inside" (Codex round 2: "Copy" one unit before
        // "opy Copyright" must cut "opy", not the visible "Copy" in "Copyright")
        let copy = HiddenText.place(d1: 1, d2: 14, length: 13, nodeLength: 4)
        XCTAssertEqual(copy?.range, 0..<3)
        XCTAssertEqual(copy?.skip, 1)
        XCTAssertEqual(copy?.exact, true)
    }

    func testLocateOnlyNearItsPlace() {
        let text = "Copyright 2026. Done.Copy That was it."
        let at = (text as NSString).range(of: "Copy That").location
        XCTAssertEqual(HiddenText.locate("Copy", in: text, near: at..<at + 4), at..<at + 4)
        // never the visible "Copy" in "Copyright" far away, nor a place with the string twice
        XCTAssertNil(HiddenText.locate("Copy", in: text, near: 30..<34, slack: 2))
        XCTAssertNil(HiddenText.locate("ab", in: "ab ab", near: 0..<2, slack: 3))
        XCTAssertNil(HiddenText.locate("   ", in: "a   b", near: 1..<4))
        XCTAssertNil(HiddenText.locate("long string", in: "short", near: 0..<5))
    }

    func testRepeatedHeadingsSafetyNet() {
        let text = "Done." + heading + body
        let r = HiddenText.repeatedHeadings(text)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(HiddenText.cut(text, ranges: r).text, "Done. " + body)
        // a long message's heading is cut short with "…"
        let said = "You said: I've been having issues with Talk & Read, specifically…"
        let message = "I've been having issues with Talk & Read, specifically in the projects view."
        XCTAssertEqual(HiddenText.cut(said + message, ranges: HiddenText.repeatedHeadings(said + message)).text, message)
        // the heading's straight apostrophes against the message's curly ones
        let curly = "Claude responded: That's right, there's nothing else.That’s right, there’s nothing else. More."
        XCTAssertEqual(HiddenText.cut(curly, ranges: HiddenText.repeatedHeadings(curly)).text, "That’s right, there’s nothing else. More.")
        XCTAssertEqual(HiddenText.cut("a\u{FFFC}\u{FFFC} b", ranges: HiddenText.objectReplacements("a\u{FFFC}\u{FFFC} b")).text, "a b")
        // the longest repeat wins: the whole heading, not its first "I love you."
        let love = "You said: I love you. I love you. Stay.I love you. I love you. Stay."
        XCTAssertEqual(HiddenText.cut(love, ranges: HiddenText.repeatedHeadings(love)).text, "I love you. I love you. Stay.")
        let hello = "You said: hello world, hello world,hello world, hello world,"
        XCTAssertEqual(HiddenText.cut(hello, ranges: HiddenText.repeatedHeadings(hello)).text, "hello world, hello world,")
        // a heading at the very end has no copy to repeat
        XCTAssertEqual(HiddenText.repeatedHeadings("Done. You said: a sentence long enough"), [])
        // a mention of the words, with no copy after it, stays
        for kept in ["You said: we would meet at noon. Then we did.", "Claude responded: no. No.", "You said: "] {
            XCTAssertEqual(HiddenText.repeatedHeadings(kept), [], kept)
        }
    }

    func testSafetyNetForACopy() {
        // what Chromium's Copy gives for a selection across a message start: no tree to place the heading
        let copied = "so leave it open.\u{FFFC}Quick note\n" + heading + body
        let net = HiddenText.safetyNet(copied)
        XCTAssertEqual(net.text, "so leave it open. Quick note\n" + body)
        XCTAssertEqual(net.removed, heading.utf16.count + 1)   // the heading and one placeholder
        // nothing repeated: untouched, placeholders included
        XCTAssertEqual(HiddenText.safetyNet("a\u{FFFC}b").text, "a\u{FFFC}b")
        XCTAssertEqual(HiddenText.safetyNet("a\u{FFFC}b").removed, 0)
        XCTAssertEqual(HiddenText.safetyNet("x", removed: 3).text, "x")
    }

    func testVisibility() {
        let root = V()
        func child(_ v: V, _ role: String, _ classes: [String], claude: Bool = true) -> V { v.child(role: role, classes: classes, claude: claude) }
        XCTAssertTrue(child(root, "AXStaticText", []).drawsText)
        // sr-only, and everything inside it, in any app
        let heading = child(root, "AXHeading", ["sr-only", "select-none"], claude: false)
        XCTAssertTrue(heading.hidden)
        XCTAssertFalse(child(heading, "AXStaticText", []).drawsText)
        XCTAssertTrue(child(root, "AXGroup", ["visually-hidden"], claude: false).hidden)
        XCTAssertTrue(child(root, "AXGroup", ["sr-only", "md:not-sr-only"]).drawsText)   // shown somewhere
        // Claude's hover toolbar and timestamp box; elsewhere a toolbar or an h-0 box may be drawn
        XCTAssertTrue(child(child(root, "AXToolbar", []), "AXStaticText", []).hidden)
        XCTAssertTrue(child(root, "AXToolbar", [], claude: false).drawsText)
        XCTAssertTrue(child(root, "AXGroup", ["relative", "h-0", "w-full"]).hidden)
        XCTAssertTrue(child(root, "AXGroup", ["relative", "h-0", "w-full"], claude: false).drawsText)
        // an h-0 box whose height anything else sets, that grows or shows its overflow is text
        for shown in [["flex-1", "h-0", "overflow-auto"], ["h-0", "md:h-auto"], ["h-0", "group-hover:h-auto"], ["h-0", "data-[state=open]:h-auto"],
                      ["h-0", "min-h-10"], ["h-0", "size-4"], ["h-0", "overflow-visible"], ["h-0", "h-fit"], ["md:h-0"]] {
            XCTAssertTrue(child(root, "AXGroup", shown).drawsText, "\(shown)")
        }
        // user-select: none is drawn (an inline session link), so it is read
        XCTAssertTrue(child(root, "AXButton", ["select-none"]).drawsText)
    }
}
