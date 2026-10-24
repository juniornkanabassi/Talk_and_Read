import XCTest
@testable import TalkReadCore

final class ParagraphsTests: XCTestCase {
    private let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima"]

    /// Ten words, so seven of them make a long dictation.
    private func sentence(_ name: String) -> String { "\(name) goes with eight other plain words to make ten." }

    private func pauses(_ names: [String], _ long: [Int: Double] = [:]) -> [Paragraphs.Pause] {
        names.indices.dropFirst().map { Paragraphs.Pause(word: names[$0].lowercased(), seconds: long[$0] ?? 0.2) }
    }

    /// The sentences (by name) in each paragraph of the result.
    private func paragraphs(_ count: Int, _ long: [Int: Double] = [:], pauses given: Bool = true) -> [[String]] {
        let used = Array(names.prefix(count))
        let out = Paragraphs.split(used.map(sentence).joined(separator: " "), pauses: given ? pauses(used, long) : [])
        return out.components(separatedBy: "\n\n").map { p in used.filter { p.contains("\($0) goes") } }
    }

    func testBreaksAtClearPauses() {
        XCTAssertEqual(paragraphs(8, [2: 1.3, 5: 1.1]),
                       [["Alpha", "Bravo"], ["Charlie", "Delta", "Echo"], ["Foxtrot", "Golf", "Hotel"]])
        XCTAssertEqual(paragraphs(7, [2: 0.99]), [Array(names[0..<2]), Array(names[2..<7])],
                       "0.99 s is no clear pause, but it is the longest among sentences 3 to 6, so the forced break lands there")
    }

    func testNoPausesBreaksEveryFiveSentences() {
        let expected = [Array(names[0..<5]), Array(names[5..<10]), Array(names[10..<12])]
        XCTAssertEqual(paragraphs(12, pauses: false), expected, "no timing at all (Apple's recogniser)")
        XCTAssertEqual(paragraphs(12), expected, "all pauses alike")
    }

    func testForcedBreakIsAtTheLongestPauseOfSentencesThreeToSix() {
        XCTAssertEqual(paragraphs(12, [3: 0.8]),
                       [Array(names[0..<3]), Array(names[3..<8]), Array(names[8..<12])])
        XCTAssertEqual(paragraphs(12, [1: 0.9, 4: 0.5]), [Array(names[0..<4]), Array(names[4..<9]), Array(names[9..<12])],
                       "sentence 2 is outside the window, so the 0.5 s pause before sentence 5 wins")
    }

    func testNoOneSentenceParagraphAtTheEnd() {
        XCTAssertEqual(paragraphs(7, [6: 1.5]), [Array(names[0..<5]), Array(names[5..<7])], "a 1.5 s pause before the last sentence is ignored")
        XCTAssertEqual(Paragraphs.breaks([0, 0, 0, 0, 0, 5.0]), [4], "nor does a forced break go before the last sentence")
        XCTAssertEqual(paragraphs(7, [5: 1.5]), [Array(names[0..<5]), Array(names[5..<7])])
        XCTAssertEqual(paragraphs(6, pauses: false), [Array(names[0..<4]), Array(names[4..<6])], "the forced break leaves two sentences")
        XCTAssertEqual(paragraphs(7, pauses: false), [Array(names[0..<5]), Array(names[5..<7])])
    }

    func testShortDictationIsUnchanged() {
        let spoken = names.prefix(5).map(sentence).joined(separator: " ").dropLast()   // 50 words, no full stop
        let everyPause = Dictionary(uniqueKeysWithValues: (1..<5).map { ($0, 2.0) })
        XCTAssertEqual(Paragraphs.split(String(spoken), pauses: pauses(Array(names.prefix(5)), everyPause)), String(spoken))
    }

    func testLastSentenceGetsAFullStop() {
        let text = (1...65).map { "word\($0)" }.joined(separator: " ")   // one long sentence: nothing to break
        XCTAssertEqual(Paragraphs.split(text), text + ".")
        XCTAssertEqual(Paragraphs.split(text + "?"), text + "?", "an end mark stays")
        XCTAssertEqual(Paragraphs.split(text + "."), text + ".")
    }

    func testListsAreLeftWhole() {
        let line = { (n: [String]) in n.map(self.sentence).joined(separator: " ") }
        let text = [line(["Alpha", "Bravo", "Charlie", "Delta"]), "1. " + line(["Echo", "Foxtrot"]),
                    "2. " + line(["Golf", "Hotel"]), "3. " + line(["India"])].joined(separator: "\n")
        let out = Paragraphs.split(text, pauses: pauses(Array(names.prefix(9)), Dictionary(uniqueKeysWithValues: (1..<9).map { ($0, 1.5) })))
        XCTAssertEqual(out.components(separatedBy: "\n1. ")[1], text.components(separatedBy: "\n1. ")[1], "the list is verbatim")
        XCTAssertTrue(out.hasPrefix(sentence("Alpha") + "\n\n" + sentence("Bravo") + "\n\n" + sentence("Charlie") + " " + sentence("Delta") + "\n1. "))
    }

    func testSpokenParagraphBreaksAreKept() {
        let text = names.prefix(3).map(sentence).joined(separator: " ") + "\n\n" + names[3..<10].map(sentence).joined(separator: " ")
        let out = Paragraphs.split(text, pauses: pauses(Array(names.prefix(10)), Dictionary(uniqueKeysWithValues: (1..<10).map { ($0, 1.5) })))
        XCTAssertTrue(out.contains(sentence("Charlie") + "\n\n" + sentence("Delta")), "the spoken break stays one break")
        XCTAssertFalse(out.contains("\n\n\n"))
        let oneLine = Paragraphs.split(text.replacingOccurrences(of: "\n\n", with: "\n"))
        XCTAssertTrue(oneLine.contains(sentence("Charlie") + "\n" + sentence("Delta")), "a spoken new line stays one line break")
    }

    func testCapitalisedAfterABreak() {
        let sentences = ["Alpha goes with eight other plain words to make ten.", "Bravo goes with eight other plain words to make ten.",
                         "Charlie goes with eight other plain words to make ten.", "delta goes with eight other plain words to make ten.",
                         "Echo goes with eight other plain words to make ten.", "iPhone goes with eight other plain words to make ten.",
                         "Golf goes with eight other plain words to make ten.", "bbc.co.uk goes with eight other plain words to make ten."]
        let heard = ["alpha", "bravo", "charlie", "delta", "echo", "iphone", "golf", "bbccouk"]
        let out = Paragraphs.split(sentences.joined(separator: " "), pauses: heard.indices.dropFirst().map { Paragraphs.Pause(word: heard[$0], seconds: 1.4) })
        XCTAssertTrue(out.contains("\n\nDelta goes"))
        XCTAssertTrue(out.contains("\n\niPhone goes"), "a vocabulary spelling keeps its case")
        XCTAssertTrue(out.contains("\n\nbbc.co.uk goes") || out.contains(" bbc.co.uk goes"), "an address keeps its case")
    }

    func testFrench() {
        let s = ["Bonjour à tous et bienvenue dans cette nouvelle vidéo sur le championnat de France.",
                 "Aujourd'hui je voudrais parler de la lutte pour le titre qui devient vraiment très serrée.",
                 "Depuis le début de la saison, plusieurs équipes se disputent la première place du classement.",
                 "Est-ce que le leader actuel peut vraiment tenir le rythme jusqu'à la fin ?",
                 "Je ne le pense pas, car son calendrier devient beaucoup plus difficile en hiver.",
                 "écoutons maintenant ce que disent les chiffres, et surtout ce qu'ils ne disent pas.",
                 "Les statistiques montrent une défense solide mais une attaque parfois trop prévisible."]
        let heard = ["bonjour", "aujourdhui", "depuis", "estce", "je", "écoutons", "les"]
        let seconds = [0, 0.3, 0.3, 1.3, 0.3, 1.2, 0.3]
        let out = Paragraphs.split(s.joined(separator: " "), pauses: heard.indices.dropFirst().map { Paragraphs.Pause(word: heard[$0], seconds: seconds[$0]) })
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 3)
        XCTAssertTrue(out.contains("classement.\n\nEst-ce que"))
        XCTAssertTrue(out.contains("en hiver.\n\nÉcoutons maintenant"), "É after the break")
        XCTAssertTrue(out.contains("la fin ?\n") == false && out.contains("la fin ? Je ne"), "French spacing before ? is not touched")
    }

    func testAnExtraBoundaryInTheHeardTextDoesNotShiftThePauses() {
        // The recogniser heard "3 p.m." as a sentence end that Cleanup has since removed; its entry is skipped.
        let used = Array(names.prefix(8))
        var list = pauses(used, [5: 1.3])
        list.insert(Paragraphs.Pause(word: "on", seconds: 0.1), at: 2)
        let out = Paragraphs.split(used.map(sentence).joined(separator: " "), pauses: list)
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(out.contains("\n\nFoxtrot goes"))
    }

    func testPausesFromTimedWords() {
        let words: [(text: String, start: Double, end: Double)] = [("Hello", 0, 0.4), ("there.", 0.5, 0.9), ("Then", 2.4, 2.7),
                                                                    ("we", 2.8, 2.9), ("go?", 3.0, 3.3), ("\"Fine,\"", 3.5, 3.8), ("ok.\"", 3.9, 4.0), ("Done", 5.0, 5.2)]
        let found = Paragraphs.pauses(of: words)
        XCTAssertEqual(found.map(\.word), ["then", "fine", "done"])
        XCTAssertEqual(found.map(\.seconds)[0], 1.5, accuracy: 0.001)
        XCTAssertEqual(found.map(\.seconds)[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(found.map(\.seconds)[2], 1.0, accuracy: 0.001)
        XCTAssertEqual(Paragraphs.pauses(of: []), [])
    }
}
