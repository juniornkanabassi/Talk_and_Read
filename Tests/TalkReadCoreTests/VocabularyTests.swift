import AppKit
import XCTest
@testable import TalkReadCore

/// Junior's vocabulary candidates (names only) as the vocabulary, with the app's spell checker as `isWord`: correct text
/// must come out as it would with no vocabulary at all, the known mishearings must be fixed, and `<unk>` is never typed.
final class VocabularyTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let vocabulary: [String: String] = {
        let data = (try? Data(contentsOf: fixtures.appendingPathComponent("vocabulary-candidates.json"))) ?? Data()
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    /// As DictationController.isCommonWord: in the British or American dictionary in lower case.
    private func isWord(_ word: String) -> Bool {
        ["en_GB", "en_US"].contains {
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0, language: $0, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    private func clean(_ text: String, vocabulary: [String: String]? = nil) -> String {
        Cleanup.apply(text, vocabulary: vocabulary ?? Self.vocabulary, removeFillers: true, isWord: isWord)
    }

    func testTheCandidateListLoaded() {
        XCTAssertEqual(Self.vocabulary.count, 32)
    }

    func testCorrectTextIsLeftAlone() {
        for text in ["Mbappé's goal was the best.", "Lamine Yamal is better.", "Bayern 2–0 Arsenal.", "I feel desire.", "Jamal Musiala scored.",
                     "Read Marca today.", "Fernando Torres retired.", "Pedro won it.", "Ligue 2 starts soon.", "An Argentinian player.",
                     "María came too.", "Yamal's goal counted.", "Dembélé and Kvaratskhelia started."] {
            XCTAssertEqual(clean(text), clean(text, vocabulary: [:]), text)
        }
        let fixture = Self.fixtures.appendingPathComponent("dictation-hard/05-psg.txt")
        let psg = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
        XCTAssertFalse(psg.isEmpty)
        XCTAssertEqual(clean(psg), clean(psg, vocabulary: [:]))
    }

    func testNoNeighbouringWordOrDigitIsSwallowed() {
        for text in ["LamineYama is better.", "LamineYama 2 goals.", "Say LamineYama is here."] {
            let out = clean(text)
            XCTAssertEqual(out.contains("Lamine Yamal"), false, text)
            XCTAssertEqual(out, clean(text, vocabulary: [:]), text)
        }
        XCTAssertEqual(clean("Joan Neves"), "Joan Neves", "no João in this vocabulary")
        XCTAssertEqual(Cleanup.apply("Joan Neves", vocabulary: ["João Neves": "João Neves"], removeFillers: true, isWord: { $0.lowercased() == "joan" }), "João Neves")
    }

    func testKnownMishearingsAreFixed() {
        XCTAssertTrue(clean("Is PHG bigger than Juve?").contains("PSG"))
        XCTAssertTrue(clean("If Mbappe is not French").contains("Mbappé is"))
        XCTAssertTrue(clean("Mbappe's goal").contains("Mbappé's goal"), "the possessive keeps its ending")
        XCTAssertTrue(clean("Dembele's run").contains("Dembélé's run"))
        XCTAssertTrue(clean("Why is La Mina Mal so good").contains("Lamine Yamal so good"))
        XCTAssertTrue(clean("PHE and Byron are unique").contains("Bayern"))
        XCTAssertTrue(clean("much better as Kvaratskelia, Dembele").contains("Kvaratskhelia"), "a near miss that is no explicit key")
    }

    func testUnkIsNeverTyped() {
        XCTAssertTrue(clean("only At<unk>tico Madrid").contains("Atlético Madrid"), "an explicit key still matches first")
        XCTAssertTrue(clean("Desir<unk> Douay is better").contains("Désiré Doué"))
        XCTAssertTrue(clean("La Mi<unk>a Mal and La Mi<unk>a Mole").contains("Lamine Yamal and Lamine Yamal"))
        for text in ["Super Copa de Espa<unk>a", "Juan D<unk>az said so", "<unk> alone <unk>", "ya se<unk>ora"] {
            XCTAssertFalse(clean(text).contains("<unk>"), text)
            XCTAssertFalse(clean(text, vocabulary: [:]).contains("<unk>"), text)
        }
        XCTAssertEqual(clean("At<unk>tico", vocabulary: [:]), "Attico")
    }
}
