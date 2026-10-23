import XCTest
@testable import TalkReadCore

final class AutoLearnTests: XCTestCase {
    private typealias C = AutoLearn.Correction

    /// The field before and after, with the dictation `said` pasted after `lead`.
    private func found(_ lead: String, _ said: String, _ tail: String = "", after: String) -> [C] {
        let before = lead + said + tail
        let start = (lead as NSString).length
        return AutoLearn.corrections(before: before, after: after, inserted: start..<start + (said as NSString).length)
    }

    func testRespeltNameInsideTheDictation() {
        XCTAssertEqual(found("Dear team, ", "the Kaparo test applies.", after: "Dear team, the Caparo test applies."),
                       [C(heard: "Kaparo", typed: "Caparo")])
        XCTAssertEqual(found("", "This is Junior Nkana Bassi from Footballco.", after: "This is Junior Nkanabassi from Footballco."),
                       [C(heard: "Nkana Bassi", typed: "Nkanabassi")])
        XCTAssertEqual(found("", "Dembele scored.", after: "Dembélé scored."), [C(heard: "Dembele", typed: "Dembélé")])
        XCTAssertEqual(found("", "watch the flick on", after: "watch the Flick on"), [C(heard: "flick", typed: "Flick")], "a case fix counts")
    }

    func testTwoCorrectionsInOneDictation() {
        XCTAssertEqual(found("", "Kvara and Vitina started.", after: "Kvaratskhelia and Vitinha started."),
                       [C(heard: "Vitina", typed: "Vitinha")], "Kvara → Kvaratskhelia is too different to be a re-spelling")
        XCTAssertEqual(found("", "Kaparo and Donahue apply.", after: "Caparo and Donoghue apply."),
                       [C(heard: "Kaparo", typed: "Caparo"), C(heard: "Donahue", typed: "Donoghue")])
    }

    func testRewordingsNumbersAddressesAndCodeAreNotLearnt() {
        XCTAssertEqual(found("", "a good result", after: "a great result"), [], "rewording")
        XCTAssertEqual(found("", "meet at 7", after: "meet at 8"), [])
        XCTAssertEqual(found("", "mail junior at footballco", after: "mail junior@footballco.com"), [])
        XCTAssertEqual(found("", "call get user name", after: "call get_user_name"), [])
        XCTAssertEqual(found("", "a test", after: "a test that is longer now"), [], "added words are not corrections")
        XCTAssertEqual(found("", "one two three four five", after: "uno dos tres quatro cinco"), [], "more than 3 words")
    }

    func testEditsOutsideTheDictationAreIgnored() {
        XCTAssertEqual(found("Kaparo was cited. ", "Then more.", after: "Caparo was cited. Then more."), [])
        XCTAssertEqual(found("", "the Kaparo test", " Tail Kaparo", after: "the Kaparo test Tail Caparo"), [])
        XCTAssertEqual(found("", "the Kaparo test", " end", after: "the Caparo test end and more typed"), [],
                       "a change that reaches past the dictation is not trusted")
        XCTAssertEqual(found("", "same", after: "same"), [])
    }

    func testTypingOnAfterTheDictationStillCountsTheCorrection() {
        XCTAssertEqual(found("", "the Kaparo test", after: "the Caparo test, which the court applied"),
                       [C(heard: "Kaparo", typed: "Caparo")])
    }

    func testAPairIsOfferedOnceItsSeenTwice() {
        var counts: [String: Int] = [:]
        let c = C(heard: "Kaparo", typed: "Caparo")
        XCTAssertEqual(AutoLearn.record([c, c], in: &counts), [], "once per dictation")
        XCTAssertEqual(AutoLearn.record([c], in: &counts), [c])
        XCTAssertEqual(AutoLearn.record([c], in: &counts), [], "offered only once")
    }
}
