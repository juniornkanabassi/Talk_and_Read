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
        // English with a French quotation: English is the top hypothesis
        XCTAssertEqual(Language.detect("The committee met on Tuesday and approved the budget after a long discussion. The members thanked the clerk for her careful work over the past year. \"C'est la vie,\" she said, shrugging, and the meeting ended."), "en")
        // sentences alternating between the two: French tops at only 0.54, below the 0.7 bar
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

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
    }
}
