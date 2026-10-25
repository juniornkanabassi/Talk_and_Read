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
        XCTAssertEqual(removed, u(text) - u(out))
        // no cut, clamped and overlapping ranges
        XCTAssertEqual(HiddenText.cut("abc", ranges: []).text, "abc")
        XCTAssertEqual(HiddenText.cut("abc def", ranges: [3..<4, 2..<3, 5..<99]).text, "ab d")
        XCTAssertEqual(HiddenText.cut("one two", ranges: [3..<4]).text, "onetwo".replacingOccurrences(of: "et", with: "e t"))
    }

    func testStringFallbackCutsEachOnceInOrder() {
        let text = "A. " + heading + body + " B. " + heading + body
        let (out, removed) = HiddenText.cut(text, strings: [heading, "   ", "not there", heading])
        XCTAssertEqual(out, "A. " + body + " B. " + body)
        XCTAssertEqual(removed, 2 * heading.utf16.count)
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
        XCTAssertEqual(net.removed, copied.utf16.count - net.text.utf16.count)
        // nothing repeated: untouched, placeholders included
        XCTAssertEqual(HiddenText.safetyNet("a\u{FFFC}b").text, "a\u{FFFC}b")
        XCTAssertEqual(HiddenText.safetyNet("a\u{FFFC}b").removed, 0)
        XCTAssertEqual(HiddenText.safetyNet("x", removed: 3).text, "x")
    }

    func testVisibility() {
        let root = V()
        XCTAssertTrue(root.child(role: "AXStaticText", classes: []).drawsText)
        // sr-only, and everything inside it
        let heading = root.child(role: "AXHeading", classes: ["sr-only", "select-none"])
        XCTAssertTrue(heading.hidden)
        XCTAssertFalse(heading.child(role: "AXStaticText", classes: []).drawsText)
        XCTAssertTrue(root.child(role: "AXGroup", classes: ["visually-hidden"]).hidden)
        XCTAssertTrue(root.child(role: "AXToolbar", classes: []).child(role: "AXStaticText", classes: []).hidden)
        // a zero-height box hangs hover labels; a growing one is a flex layout's pane
        XCTAssertTrue(root.child(role: "AXGroup", classes: ["relative", "h-0", "w-full"]).hidden)
        XCTAssertTrue(root.child(role: "AXGroup", classes: ["flex-1", "h-0", "overflow-auto"]).drawsText)
        // user-select: none is drawn (an inline session link), so it is read
        XCTAssertTrue(root.child(role: "AXButton", classes: ["select-none"]).drawsText)
    }
}
