import XCTest
@testable import TalkReadCore

final class CleanupTests: XCTestCase {
    private func clean(_ s: String, _ vocabulary: [String: String] = [:], fillers: Bool = true) -> String {
        Cleanup.apply(s, vocabulary: vocabulary, removeFillers: fillers)
    }

    func testFillersWithTheirCommaAreRemoved() {
        XCTAssertEqual(clean("so um, I think uh we should go"), "So I think we should go")
        XCTAssertEqual(clean("Umm hello there"), "Hello there")
        XCTAssertEqual(clean("well erm, ah, hmm okay"), "Well okay")
        XCTAssertEqual(clean("it is er fine."), "It is fine.")
        XCTAssertEqual(clean("I said um."), "I said.")
    }

    func testParagraphBreaksSurviveAndTheNextWordIsCapitalised() {
        XCTAssertEqual(clean("we are done here.\n\nso um, the next part starts.\n\nuh then it ends."),
                       "We are done here.\n\nSo the next part starts.\n\nThen it ends.")
        XCTAssertEqual(clean("it was good. \n\n  \u{00E9}coutons ça."), "It was good.\n\n\u{00C9}coutons ça.")
    }

    func testFillersOnlyAsWholeWords() {
        XCTAssertEqual(clean("the umbrella is humming, ahead of her"), "The umbrella is humming, ahead of her")
    }

    func testFillersKeptWhenSwitchedOff() {
        XCTAssertEqual(clean("so um I think", fillers: false), "So um I think")
        // Each language's own fillers; a filler that is a real word in a chosen language stays.
        XCTAssertEqual(Cleanup.apply("Alors euh je pense que oui.", vocabulary: [:], removeFillers: true, languages: ["en", "fr"]), "Alors je pense que oui.")
        XCTAssertEqual(Cleanup.apply("Er kommt äh morgen.", vocabulary: [:], removeFillers: true, languages: ["en", "de"]), "Er kommt morgen.")
        XCTAssertEqual(Cleanup.apply("Quero um café.", vocabulary: [:], removeFillers: true, languages: ["pt"]), "Quero um café.")
        XCTAssertEqual(Cleanup.apply("Wir treffen uns um acht.", vocabulary: [:], removeFillers: true, languages: ["en", "de"]), "Wir treffen uns um acht.")
        XCTAssertEqual(Cleanup.apply("Ah bon, d'accord.", vocabulary: [:], removeFillers: true, languages: ["en", "fr"]), "Ah bon, d'accord.")
    }

    func testFillerRemovalKeepsLineBreaks() {
        XCTAssertEqual(clean("one new line um two"), "One\nTwo")
    }

    func testSpokenPunctuation() {
        XCTAssertEqual(clean("hello comma world full stop"), "Hello, world.")
        XCTAssertEqual(clean("is it ready question mark"), "Is it ready?")
        XCTAssertEqual(clean("wow exclamation mark"), "Wow!")
        XCTAssertEqual(clean("great exclamation point"), "Great!")
        XCTAssertEqual(clean("note colon buy milk semicolon eggs"), "Note: buy milk; eggs")
        XCTAssertEqual(clean("the end period"), "The end.")
        XCTAssertEqual(clean("wait dash what"), "Wait – what")
        XCTAssertEqual(clean("he said open quote hello there close quote and left"), "He said \"hello there\" and left")
    }

    func testPunctuationIsCaseInsensitiveAndAbsorbsTheModelsOwnMark() {
        XCTAssertEqual(clean("Hello Comma world Full Stop."), "Hello, world.")
        XCTAssertEqual(clean("hello comma, world."), "Hello, world.")
        // A recogniser that punctuates by itself (Parakeet v3) and a spoken mark give one mark, the spoken one.
        XCTAssertEqual(clean("Hi John, comma how are you?"), "Hi John, how are you?")
        XCTAssertEqual(clean("Is it ready in five seconds? question mark"), "Is it ready in five seconds?")
        XCTAssertEqual(clean("It's done. Question mark"), "It's done?")
        XCTAssertEqual(clean("Really question mark exclamation mark"), "Really?!", "a mark a command made is kept")
        // French commands with French on; English ones still work, and "point" alone is a word.
        let fr = { (s: String) in Cleanup.apply(s, vocabulary: [:], removeFillers: true, languages: ["en", "fr"]) }
        XCTAssertEqual(fr("Bonjour virgule comment allez-vous point d'interrogation"), "Bonjour, comment allez-vous?")
        XCTAssertEqual(fr("C'est le point important point final à la ligne Ensuite deux-points rien"), "C'est le point important.\nEnsuite: rien")
        XCTAssertEqual(fr("Hello comma world full stop"), "Hello, world.")
        XCTAssertEqual(clean("Bonjour virgule"), "Bonjour virgule", "French commands only with French on")
        XCTAssertEqual(clean("The end. New paragraph Next part"), "The end.\n\nNext part", "a line break keeps the full stop")
    }

    func testNewLineAndNewParagraph() {
        XCTAssertEqual(clean("first line new line second line"), "First line\nSecond line")
        XCTAssertEqual(clean("para one full stop new paragraph para two"), "Para one.\n\nPara two")
    }

    func testPunctuationSpacing() {
        XCTAssertEqual(clean("one , two ; three"), "One, two; three")
        XCTAssertEqual(clean("a   b    c"), "A b c")
        XCTAssertEqual(clean("  padded  "), "Padded")
    }

    func testCapitalisation() {
        XCTAssertEqual(clean("hello. how are you? fine! ok"), "Hello. How are you? Fine! Ok")
        XCTAssertEqual(clean("line one\nline two"), "Line one\nLine two")
        XCTAssertEqual(clean("it costs 3.5 dollars"), "It costs 3.5 dollars")
        XCTAssertEqual(clean("\"quoted start\" then more"), "\"Quoted start\" then more")
        XCTAssertEqual(clean("42 apples. then pears"), "42 apples. Then pears")
        XCTAssertEqual(clean(""), "")
    }

    func testVocabularyReplacesWholeWordsCaseInsensitivelyLongestFirst() {
        let vocab = ["open ai": "OpenAI", "open": "Open", "kubernetes": "Kubernetes", "ios": "iOS"]
        XCTAssertEqual(clean("we use Open AI and kubernetes on ios", vocab), "We use OpenAI and Kubernetes on iOS")
        XCTAssertEqual(clean("reopen the openings", vocab), "Reopen the openings", "only whole words")
        XCTAssertEqual(clean("ios is great. kubernetes too", vocab), "iOS is great. Kubernetes too", "a vocabulary spelling is kept at a sentence start")
    }

    func testVocabularyDoesNotChain() {
        XCTAssertEqual(clean("a b", ["a": "b", "b": "c"]), "b c")
    }

    func testVocabularyKeyWithRegexCharactersIsLiteral() {
        XCTAssertEqual(clean("see c++ docs and a.b", ["c++": "C plus plus", "a.b": "A-B"]), "See C plus plus docs and A-B")
        XCTAssertEqual(clean("axb", ["a.b": "A-B"]), "Axb")
    }

    func testVocabularyRunsAfterPunctuation() {
        XCTAssertEqual(clean("tell sam comma now", ["sam": "Sam"]), "Tell Sam, now")
    }

    func testUrlsAreLeftAlone() {
        XCTAssertEqual(clean("go to https://example.com/new-line/um/period comma now"), "Go to https://example.com/new-line/um/period, now")
    }

    func testUrlSurvivesIntactWithTrailingPunctuationAndVocabulary() {
        XCTAssertEqual(clean("see www.open.com full stop", ["open": "Open"]), "See www.open.com.")
        XCTAssertEqual(clean("visit https://example.com/path?a=1. then stop"), "Visit https://example.com/path?a=1. Then stop")
        XCTAssertEqual(clean("https://example.com is lowercase"), "https://example.com is lowercase")
    }

    func testMixedSentence() {
        let raw = "um so hello comma this is a test full stop new paragraph uh is it working question mark open quote yes close quote he said full stop"
        XCTAssertEqual(clean(raw, ["talk and read": "Talk & Read"]), "So hello, this is a test.\n\nIs it working? \"Yes\" he said.")
        XCTAssertEqual(clean("um try talk and read period", ["talk and read": "Talk & Read"]), "Try Talk & Read.")
    }

    func testInputPlaceholderCharactersCannotInjectText() {
        XCTAssertEqual(clean("a\u{E000}0\u{E001} b"), "A0 b")
    }
}
