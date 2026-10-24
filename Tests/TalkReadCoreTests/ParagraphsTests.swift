import XCTest
@testable import TalkReadCore

final class ParagraphsTests: XCTestCase {
    private let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima"]

    /// Ten words, so seven of them make a long dictation.
    private func sentence(_ name: String) -> String { "\(name) goes with eight other plain words to make ten." }

    /// One pause per sentence: 0.2 s unless `long` says otherwise (index 0 has none).
    private func pauses(_ count: Int, _ long: [Int: Double] = [:]) -> [Double?] {
        (0..<count).map { $0 == 0 ? nil : (long[$0] ?? 0.2) }
    }

    /// The sentences (by name) in each paragraph of the result.
    private func paragraphs(_ count: Int, _ long: [Int: Double] = [:], pauses given: Bool = true) -> [[String]] {
        let used = Array(names.prefix(count))
        let out = Paragraphs.split(used.map(sentence).joined(separator: " "), pauses: given ? pauses(count, long) : [])
        return out.components(separatedBy: "\n\n").map { p in used.filter { p.contains("\($0) goes") } }
    }

    func testBreaksAtClearPauses() {
        XCTAssertEqual(paragraphs(8, [2: 1.3, 5: 1.1]),
                       [["Alpha", "Bravo"], ["Charlie", "Delta", "Echo"], ["Foxtrot", "Golf", "Hotel"]])
    }

    func testUnknownPausesNeverBreak() {
        let used = Array(names.prefix(8))
        let text = used.map(sentence).joined(separator: " ")
        let unknown: [Double?] = [nil, nil, nil, 5, nil, nil, nil, nil]          // only sentence 3 is known, and long
        XCTAssertEqual(Paragraphs.split(text, pauses: unknown).components(separatedBy: "\n\n").count, 2, "a 5 s pause breaks; the rest is unknown")
        let none = [Double?](repeating: nil, count: 8)
        XCTAssertEqual(Paragraphs.split(text, pauses: none), Paragraphs.split(text, pauses: []), "unknown is the same as no pauses")
        XCTAssertEqual(Paragraphs.split(text, pauses: [0.2, 1.5]), Paragraphs.split(text, pauses: []), "a wrong count means no pauses known")
    }

    func testNoPausesBreaksEveryFiveSentences() {
        let expected = [Array(names[0..<5]), Array(names[5..<10]), Array(names[10..<12])]
        XCTAssertEqual(paragraphs(12, pauses: false), expected, "no timing at all (Apple's recogniser)")
        XCTAssertEqual(paragraphs(12), expected, "all pauses alike")
    }

    func testForcedBreakIsAtTheLongestPauseOfSentencesThreeToSix() {
        XCTAssertEqual(paragraphs(7, [2: 0.99]), [Array(names[0..<2]), Array(names[2..<7])], "0.99 s is no clear pause, but it is the longest")
        XCTAssertEqual(paragraphs(12, [3: 0.8]), [Array(names[0..<3]), Array(names[3..<8]), Array(names[8..<12])])
        XCTAssertEqual(paragraphs(12, [1: 0.9, 4: 0.5]), [Array(names[0..<4]), Array(names[4..<9]), Array(names[9..<12])],
                       "sentence 2 is outside the window, so the 0.5 s pause before sentence 5 wins")
    }

    func testNoOneSentenceParagraphAtTheEnd() {
        XCTAssertEqual(paragraphs(7, [6: 1.5]), [Array(names[0..<5]), Array(names[5..<7])], "a 1.5 s pause before the last sentence is ignored")
        XCTAssertEqual(Paragraphs.breaks([0, 0, 0, 0, 0, 5.0]), [4], "nor does a forced break go before the last sentence")
        XCTAssertEqual(paragraphs(7, pauses: false), [Array(names[0..<5]), Array(names[5..<7])])
    }

    func testShortDictationIsUnchanged() {
        let spoken = names.prefix(5).map(sentence).joined(separator: " ").dropLast()   // 50 words, no full stop
        XCTAssertEqual(Paragraphs.split(String(spoken), pauses: pauses(5, [1: 2, 2: 2, 3: 2, 4: 2])), String(spoken))
        XCTAssertEqual(Paragraphs.tidy(String(spoken)), String(spoken))
    }

    func testOnlyWhiteSpaceBetweenSentencesChanges() {
        let text = names.prefix(8).map(sentence).joined(separator: "  ")           // two spaces
        let out = Paragraphs.split(text, pauses: pauses(8, [3: 2]))
        XCTAssertEqual(out.replacingOccurrences(of: "\n\n", with: "  "), text)
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 2)
    }

    func testNoBreakNextToASpokenParagraphOrLine() {
        // The recogniser wrote "New paragraph." as a sentence of its own; no break goes within a sentence of it.
        var parts = names.prefix(10).map(sentence)
        parts.insert("New paragraph.", at: 3)
        let every = pauses(11, Dictionary(uniqueKeysWithValues: (1..<11).map { ($0, 1.5) }))
        let out = Paragraphs.split(parts.joined(separator: " "), pauses: every)
        XCTAssertTrue(out.contains(sentence("Bravo") + " " + sentence("Charlie") + " New paragraph. " + sentence("Delta")), "nothing at the command or either side")
        XCTAssertTrue(out.contains(sentence("Alpha") + "\n\n" + sentence("Bravo")), "an ordinary break earlier is fine")
        let line = Paragraphs.split(parts.joined(separator: " ").replacingOccurrences(of: "New paragraph.", with: "New line."), pauses: every)
        XCTAssertTrue(line.contains(" New line. "))
    }

    func testBreaksAlreadyInTheTextAreKept() {
        let text = names.prefix(3).map(sentence).joined(separator: " ") + "\n\n" + names[3..<10].map(sentence).joined(separator: " ")
        let out = Paragraphs.split(text, pauses: pauses(10, Dictionary(uniqueKeysWithValues: (1..<10).map { ($0, 1.5) })))
        XCTAssertTrue(out.contains(sentence("Charlie") + "\n\n" + sentence("Delta")))
        XCTAssertFalse(out.contains("\n\n\n"))
    }

    // MARK: Sentences (Sol's exact regressions)

    private func padded(_ middle: String) -> String {
        (names.prefix(4).map(sentence) + [middle] + names[4..<7].map(sentence)).joined(separator: " ")
    }

    func testAbbreviationsAndEllipsesAreNotSentenceEnds() {
        for middle in ["Please ask Dr. Smith about the plan before noon today.", "We live at No. 5 on the left side of the road.",
                       "I thought... perhaps we should wait until the weekend instead."] {
            let out = Paragraphs.split(padded(middle))
            XCTAssertEqual(out.components(separatedBy: "\n\n").count, 2, middle)
            XCTAssertTrue(out.contains(middle), "the sentence stays whole: \(middle)")
        }
    }

    func testFrenchClosingGuillemetStaysWithItsQuotation() {
        let middle = "Il a répondu « oui ! » Ensuite nous sommes partis ensemble."
        let out = Paragraphs.split(padded(middle))
        XCTAssertTrue(out.contains("« oui ! » Ensuite"))
        XCTAssertFalse(out.contains("!\n\n»"))
    }

    func testFilledAndRepeatedSentenceStartsDoNotMisplaceAPause() {
        // Cleanup used to drop "Um," sentence starts and shift the pauses; the split now runs before Cleanup.
        let um = (0..<8).map { $0 >= 1 && $0 <= 3 ? "Um, bit \(names[$0]) goes with eight other plain words to make ten." : sentence(names[$0]) }
        let out = Paragraphs.split(um.joined(separator: " "), pauses: pauses(8, [4: 1.3]))
        XCTAssertTrue(out.contains("\n\n" + sentence("Echo")))
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(Cleanup.apply(out, vocabulary: [:], removeFillers: true).contains("\n\n" + sentence("Echo")), "Cleanup keeps the break")
        let so = (0..<8).map { "So, " + sentence(names[$0]).lowercased() }
        let again = Paragraphs.split(so.joined(separator: " "), pauses: pauses(8, [5: 1.3]))
        XCTAssertTrue(again.contains("\n\nSo, foxtrot goes"), "repeated first words: the pause belongs to sentence 5")
        XCTAssertEqual(again.components(separatedBy: "\n\n").count, 2)
    }

    func testFrench() {
        let s = ["Bonjour à tous et bienvenue dans cette nouvelle vidéo sur le championnat de France.",
                 "Aujourd'hui je voudrais parler de la lutte pour le titre qui devient vraiment très serrée.",
                 "Depuis le début de la saison, plusieurs équipes se disputent la première place du classement.",
                 "Est-ce que le leader actuel peut vraiment tenir le rythme jusqu'à la fin ?",
                 "Je ne le pense pas, car son calendrier devient beaucoup plus difficile en hiver.",
                 "Écoutons maintenant ce que disent les chiffres, et surtout ce qu'ils ne disent pas.",
                 "Les statistiques montrent une défense solide mais une attaque parfois trop prévisible."]
        let out = Paragraphs.split(s.joined(separator: " "), pauses: [nil, 0.3, 0.3, 1.3, 0.3, 1.2, 0.3])
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 3)
        XCTAssertTrue(out.contains("classement.\n\nEst-ce que"))
        XCTAssertTrue(out.contains("en hiver.\n\nÉcoutons maintenant"))
        XCTAssertTrue(Cleanup.apply(out, vocabulary: [:], removeFillers: true).contains("en hiver.\n\nÉcoutons maintenant"), "Cleanup keeps the break")
    }

    // MARK: Words and pauses

    func testWordsFromPieces() {
        typealias P = Paragraphs.Piece
        typealias W = Paragraphs.Word
        XCTAssertEqual(Paragraphs.words(from: [P(text: " Hel", start: 0, end: 0.1), P(text: "lo", start: 0.1, end: 0.2), P(text: " there", start: 0.3, end: 0.5)]),
                       [W(text: "Hello", start: 0, end: 0.2), W(text: "there", start: 0.3, end: 0.5)])
        XCTAssertEqual(Paragraphs.words(from: [P(text: " there", start: 0.3, end: 0.5), P(text: ".", start: 2.0, end: 2.1), P(text: " ?", start: 3, end: 3.1)]),
                       [W(text: "there.?", start: 0.3, end: 0.5)], "punctuation joins the word and never moves its end")
        let backwards = Paragraphs.words(from: [P(text: " big", start: 0, end: 2), P(text: "ger", start: 0.1, end: 0.2)])
        XCTAssertEqual(backwards.map(\.text), ["bigger"])
        XCTAssertEqual(backwards[0].end, 2, "the extent never shrinks")
        XCTAssertFalse(backwards[0].reliable)
        XCTAssertFalse(Paragraphs.words(from: [P(text: " odd", start: 1, end: 0.5)])[0].reliable, "a piece that ends before it starts")
        XCTAssertEqual(Paragraphs.words(from: []), [])
        XCTAssertEqual(Paragraphs.words(from: [P(text: " one", start: 1, end: 1.2)]), [W(text: "one", start: 1, end: 1.2)])
        XCTAssertEqual(Paragraphs.words(from: [P(text: "", start: 0, end: 0)]), [])
    }

    func testPausesFromTimedWords() {
        let text = "Hello there. Then we go? \"Fine,\" ok. Done"
        let words = [("Hello", 0.0, 0.4), ("there.", 0.5, 0.9), ("Then", 2.4, 2.7), ("we", 2.8, 2.9), ("go?", 3.0, 3.3),
                     ("\"Fine,\"", 3.5, 3.8), ("ok.", 3.9, 4.0), ("Done", 5.0, 5.2)].map { Paragraphs.Word(text: $0.0, start: $0.1, end: $0.2) }
        let found = Paragraphs.pauses(text: text, words: words)
        XCTAssertEqual(found.count, 4)
        XCTAssertNil(found[0])
        XCTAssertEqual(found[1] ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(found[2] ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(found[3] ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(Paragraphs.pauses(text: "", words: []), [])
    }

    func testUnknownPausesFromBadTimings() {
        let text = "One two. Three four. Five six."
        func pauses(_ edit: (inout [Paragraphs.Word]) -> Void) -> [Double?] {
            var w = [("One", 0.0, 0.2), ("two.", 0.3, 0.5), ("Three", 2.0, 2.2), ("four.", 2.3, 2.5), ("Five", 4.0, 4.2), ("six.", 4.3, 4.5)]
                .map { Paragraphs.Word(text: $0.0, start: $0.1, end: $0.2) }
            edit(&w)
            return Paragraphs.pauses(text: text, words: w)
        }
        XCTAssertEqual(pauses { _ in }.compactMap { $0 }.count, 2)
        XCTAssertNil(pauses { $0[1].reliable = false }[1], "the word before is unreliable")
        XCTAssertNil(pauses { $0[2].reliable = false }[1], "the word after is unreliable")
        XCTAssertNil(pauses { $0[2].start = -1 }[1], "words out of order")
        XCTAssertNil(pauses { $0[2].text = "Tree" }[1], "a word that is not in the text")
        XCTAssertEqual(pauses { $0[3].reliable = false }[1] ?? -1, 1.5, accuracy: 0.001, "only the boundary's own words matter")
    }

    // MARK: Tidy

    private let intro = (1...62).map { "word\($0)" }.joined(separator: " ") + "."

    func testTidyKeepsListsWhole() {
        let out = Paragraphs.tidy(intro + "\n\n1. Do the first thing. Then the next one.\n\nMore of the same item.\n2. Second.\n\n3. Third.\n\nAfter the list.")
        XCTAssertEqual(out, intro + "\n\n1. Do the first thing. Then the next one. More of the same item.\n2. Second.\n3. Third.\n\nAfter the list.")
        let bullets = Paragraphs.tidy(intro + "\n  - one\n\n  - two\n\n• three\n\n* four\n\n5) five.")
        XCTAssertEqual(bullets, intro + "\n  - one\n  - two\n• three\n* four\n5) five.")
        XCTAssertEqual(Paragraphs.tidy(intro + "\n\nNo list here.\n\nAt all."), intro + "\n\nNo list here.\n\nAt all.")
    }

    func testTidyAddsTheFinalFullStop() {
        XCTAssertEqual(Paragraphs.tidy(intro + " He said \"yes\""), intro + " He said \"yes\".")
        XCTAssertEqual(Paragraphs.tidy(intro + " See you (probably tomorrow)"), intro + " See you (probably tomorrow).")
        XCTAssertEqual(Paragraphs.tidy(intro + " Thanks"), intro + " Thanks.")
        XCTAssertEqual(Paragraphs.tidy(intro + " 2. Email Jon"), intro + " 2. Email Jon.")
        for ending in ["Thanks.", "Really?", "Stop!", "He said \"yes!\"", "Wait…", "(done.)", "Why,", "Total £5%"] {
            XCTAssertEqual(Paragraphs.tidy(intro + " " + ending), intro + " " + ending, ending)
        }
    }
}
