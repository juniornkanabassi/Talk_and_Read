import XCTest
@testable import TalkReadCore

final class LanguageTests: XCTestCase {
    func testPlainFrench() {
        XCTAssertEqual(Language.detect("Le conseil municipal a approuvé hier soir le budget de la station de sauvetage, malgré les réserves de plusieurs élus."), "fr")
        XCTAssertEqual(Language.detect("Aujourd'hui, l'homme que j'ai rencontré m'a expliqué pourquoi il préfère les trains de nuit aux avions."), "fr")
    }

    func testPlainEnglish() {
        XCTAssertEqual(Language.detect("The town council approved the lifeboat station budget last night, despite reservations from several members."), "en")
        XCTAssertEqual(Language.detect(try! String(contentsOfFile: fixture("reading.txt"), encoding: .utf8)), "en")
    }

    func testShortTextStaysEnglish() {
        XCTAssertEqual(Language.detect(""), "en")
        XCTAssertEqual(Language.detect("Bonjour tout le monde"), "en")   // 18 letters: below the 20 letter floor
        XCTAssertEqual(Language.detect("Merci beaucoup, à demain"), "fr")  // 20 letters and clearly French
    }

    func testMixedTextIsNotFrench() {
        // English with a French quotation, and the case NaturalLanguage alone scored fr 0.76: one French sentence, English text
        XCTAssertEqual(Language.detect("The committee met on Tuesday and approved the budget after a long discussion. The members thanked the clerk for her careful work over the past year. \"C'est la vie,\" she said, shrugging, and the meeting ended."), "en")
        XCTAssertEqual(Language.detect("The committee met on Tuesday and approved the budget after a long discussion. Le comité s'est réuni mardi. The members thanked the clerk for her careful work over the past year."), "en")
        // mostly French with one English sentence stays French
        XCTAssertEqual(Language.detect("Le comité s'est réuni mardi et a approuvé le budget après une longue discussion. The members thanked the clerk. Les membres ont remercié le greffier pour son travail minutieux."), "fr")
        // sentences alternating between the two hold under 60 % of the letters in French
        XCTAssertEqual(Language.detect("Le conseil a voté. The vote was close. Le budget passe. The mayor smiled."), "en")
    }

    func testFrenchWithEnglishNames() {
        XCTAssertEqual(Language.detect("Hier, Taylor Swift et Elon Musk ont visité le musée du Louvre avec les équipes d'Apple et de Google pour parler de l'avenir."), "fr")
    }

    func testOnlyTheFirst2000CharactersCount() {
        let french = String(repeating: "Le chat dort sur le canapé pendant que la pluie tombe doucement. ", count: 40)
        let english = String(repeating: "The cat sleeps on the sofa while the rain falls softly outside. ", count: 40)
        XCTAssertGreaterThan(french.count, 2000)
        XCTAssertEqual(Language.detect(french + english), "fr")
        XCTAssertEqual(Language.detect(english + french), "en")
    }

    func testFrenchFixtureIsFrench() {
        XCTAssertEqual(Language.detect(try! String(contentsOfFile: fixture("reading-fr.txt"), encoding: .utf8)), "fr")
    }

    // MARK: runs (dictation)

    private func runs(_ text: String, _ languages: [String] = ["en", "fr"], fallback: String? = nil) -> [String] {
        Language.runs(text, among: languages, fallback: fallback).map { "\($0.language): \($0.text)" }
    }

    func testRunsGiveTheTextBackExactly() {
        for text in ["", "  Hello there, how are you today? Bonjour, je vais très bien merci.  ",
                     "One sentence only", "Je pense que c'est une bonne idée. I agree with that completely.\n\nOn verra demain."] {
            XCTAssertEqual(Language.runs(text, among: ["en", "fr"]).map(\.text).joined(), text)
        }
    }

    func testRunsSplitAtTheLanguageChange() {
        XCTAssertEqual(runs("I'm recording the podcast this afternoon. Ensuite je dois appeler ma mère pour son anniversaire."),
                       ["en: I'm recording the podcast this afternoon. ", "fr: Ensuite je dois appeler ma mère pour son anniversaire."])
        XCTAssertEqual(runs("The match was brilliant from start to finish. The second half especially."),
                       ["en: The match was brilliant from start to finish. The second half especially."], "one language merges")
    }

    func testShortSentencesFollowTheOneBefore() {
        // "Oui." and "OK." are too short to place: they keep the language around them
        XCTAssertEqual(runs("Je crois que le match commence à vingt et une heures. Oui. On regarde ensemble ?"),
                       ["fr: Je crois que le match commence à vingt et une heures. Oui. On regarde ensemble ?"])
        XCTAssertEqual(runs("OK. I'll send you the script for the long-form video tonight."),
                       ["en: OK. I'll send you the script for the long-form video tonight."], "a short first sentence takes the next one's")
        XCTAssertEqual(runs("Oui merci", fallback: "fr"), ["fr: Oui merci"], "nothing placed: the fallback")
        XCTAssertEqual(runs("Oui merci"), ["en: Oui merci"], "no fallback: the first language")
    }

    func testWithoutInheritingShortSentencesAreUnknown() {
        XCTAssertEqual(runs2("I really liked the second half of that match. Ma favorite."),
                       ["en: I really liked the second half of that match. ", ": Ma favorite."])
        XCTAssertEqual(runs2("Oui merci"), [": Oui merci"])
    }

    private func runs2(_ text: String) -> [String] {
        Language.runs(text, among: ["en", "fr"], inherit: false).map { "\($0.language): \($0.text)" }
    }

    func testOneLanguageIsOneRun() {
        XCTAssertEqual(runs("Bonjour à tous, bienvenue dans le podcast de cette semaine.", ["en"]),
                       ["en: Bonjour à tous, bienvenue dans le podcast de cette semaine."])
        XCTAssertEqual(runs("Hello", ["fr"]), ["fr: Hello"])
    }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
    }
}
