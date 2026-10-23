import XCTest
@testable import TalkReadCore

/// French spoken forms (`Speakable`), French number and elision matching (`Alignment`) and the whole path (`Timeline`),
/// plus a guard that English output does not move.
final class FrenchTests: XCTestCase {
    private func fr(_ source: String) -> Speakable {
        Speakable.make(source, range: 0..<(source as NSString).length, lexicon: [:], language: "fr")
    }

    private func say(_ source: String) -> String { fr(source).text }

    /// The source text the `occurrence`th appearance of `word` in the speakable text came from.
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

    // MARK: Speakable

    func testPlainFrenchWithContractionsAndAccentsIsUntouched() {
        let s = "L'homme d’aujourd'hui a mangé à l'école, où l’été est très chaud."
        let sp = fr(s)
        XCTAssertEqual(sp.text, s)
        XCTAssertEqual(sp.sourceRange(0..<7), 0..<7)
    }

    func testCardinalNumbers() {
        XCTAssertEqual(say("21 31 61 71 81 91"), "vingt et un trente et un soixante et un soixante et onze quatre vingt un quatre vingt onze")
        XCTAssertEqual(say("16 17 19 70 77 79 80 99"), "seize dix sept dix neuf soixante dix soixante dix sept soixante dix neuf quatre vingts quatre vingt dix neuf")
        XCTAssertEqual(say("100, 101, 180, 200, 201, 280"), "cent, cent un, cent quatre vingts, deux cents, deux cent un, deux cent quatre vingts")
        XCTAssertEqual(say("1000 2000 80000 200000 1001"), "mille deux mille quatre vingt mille deux cent mille mille un")
        XCTAssertEqual(say("1000000 2000000 200000000 3000000000"), "un million deux millions deux cents millions trois milliards")
        XCTAssertEqual(say("0 007 01 23 45"), "zéro zéro zéro sept zéro un vingt trois quarante cinq")
        XCTAssertEqual(say("12 345 abonnés"), "douze mille trois cent quarante cinq abonnés")
        XCTAssertEqual(say("1\u{202F}000 et 1.000.000"), "mille et un million")
        XCTAssertEqual(say("4 500 000 euros"), "quatre millions cinq cent mille euros")
        XCTAssertEqual(say("1234567890123"), "1234567890123")   // beyond a thousand billion the engine's normaliser decides
    }

    func testDecimalsUseTheComma() {
        XCTAssertEqual(say("Il y a 4,2 millions d'habitants."), "Il y a quatre virgule deux millions d'habitants.")
        XCTAssertEqual(say("3,14 et 0,05 et 2,50 et 7,0"), "trois virgule quatorze et zéro virgule zéro cinq et deux virgule cinquante et sept virgule zéro")
        XCTAssertEqual(say("3.5 millions"), "trois virgule cinq millions")
        XCTAssertEqual(say("1, 2, 3"), "un, deux, trois")
    }

    func testYearsAndDates() {
        XCTAssertEqual(say("Le 14 novembre 2027."), "Le quatorze novembre deux mille vingt sept.")
        XCTAssertEqual(say("en 1998, en 2000 et 1900"), "en mille neuf cent quatre vingt dix huit, en deux mille et mille neuf cents")
        XCTAssertEqual(say("1er mars, 1 avril, 1re étape, 2e, 3ème, 21e, 80e"), "premier mars, premier avril, première étape, deuxième, troisième, vingt et unième, quatre vingtième")
        XCTAssertEqual(say("5e 9e 11e 14e 100e"), "cinquième neuvième onzième quatorzième centième")
        XCTAssertEqual(say("14/11/2027 et 32/13/2027"), "quatorze novembre deux mille vingt sept et trente deux/treize/deux mille vingt sept")
        XCTAssertEqual(say("1/5/2027"), "premier mai deux mille vingt sept")
        XCTAssertEqual(say("À 6h45, 11h20, 1h, 0h05 et 6:45 ou 24h"), "À six heures quarante cinq, onze heures vingt, une heure, zéro heure cinq et six heures quarante cinq ou vingt quatre h")
    }

    func testPercentTemperatureAmpersandAndMoney() {
        XCTAssertEqual(say("50 % des gens, 4,5% aussi, 12\u{A0}%."), "cinquante pour cent des gens, quatre virgule cinq pour cent aussi, douze pour cent.")
        XCTAssertEqual(say("Il fait 23°C et 5 °F, 3°."), "Il fait vingt trois degrés Celsius et cinq degrés Fahrenheit, trois degrés.")
        XCTAssertEqual(say("Tom & Jerry, R&D"), "Tom et Jerry, R et D")
        XCTAssertEqual(say("45 €, 1€, €12 et $5, 2,5 £, ~20"), "quarante cinq euros, un euro, douze euros et cinq dollars, deux virgule cinq livres, environ vingt")
        XCTAssertEqual(say("5km et 3D et H2O"), "cinq km et trois D et H2O")
        XCTAssertEqual(say("100%"), "cent pour cent")
    }

    func testURLsAndEmails() {
        XCTAssertEqual(say("Voir https://www.exemple.com/a/b?x=1 ou écrire à jean.dupont@exemple.fr."),
                       "Voir www point exemple point com ou écrire à jean point dupont arobase exemple point fr.")
        XCTAssertEqual(say("Allez sur www.exemple.org, puis http://docs.exemple.co.uk:8080/x"), "Allez sur www point exemple point org, puis docs point exemple point co point uk")
    }

    func testSourceRangesStayExactInUTF16() {
        let s = "Café 😀 le 14 novembre 2027 : 4,2 millions à 50 % d'«\u{A0}élan\u{A0}»."
        let sp = fr(s)
        XCTAssertEqual(origin(sp, "quatorze", s), "14")
        XCTAssertEqual(origin(sp, "mille", s), "2027")
        XCTAssertEqual(origin(sp, "virgule", s), "4,2")
        XCTAssertEqual(origin(sp, "cinquante", s), "50")
        XCTAssertEqual(origin(sp, "cent", s), "%")
        XCTAssertEqual(origin(sp, "élan", s), "élan")
        // every speakable unit maps inside the source
        for i in 0..<(sp.text as NSString).length {
            let r = sp.sourceRange(i..<(i + 1))
            XCTAssertTrue(r.lowerBound >= 0 && r.upperBound <= (s as NSString).length && r.lowerBound < r.upperBound, "unit \(i)")
        }
    }

    func testLexiconStillWinsInFrench() {
        let s = "Nguyen a 3 chats"
        let sp = Speakable.make(s, range: 0..<s.utf16.count, lexicon: ["Nguyen": "win"], language: "fr")
        XCTAssertEqual(sp.text, "win a trois chats")
    }

    func testEnglishOutputDoesNotChange() {
        let samples = ["It costs £45, 50% of 4,2 million & 3.5 at 23°C and 14 November 2027.", "Mail me@x.org or see https://a.io/b ~5 pounds.",
                       "1. First\n2. Second", "Plain words, punctuation and £5 stay."]
        for s in samples {
            let explicit = Speakable.make(s, range: 0..<s.utf16.count, lexicon: [:], language: "en")
            let implicit = Speakable.make(s, range: 0..<s.utf16.count, lexicon: [:])
            XCTAssertEqual(explicit.text, implicit.text)
        }
        let s = "50% & 23°C at me@x.org"
        XCTAssertEqual(Speakable.make(s, range: 0..<s.utf16.count, lexicon: [:]).text, "50 percent and 23 degrees Celsius at me at x dot org")
    }

    // MARK: Alignment

    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    private func assign(_ spoken: String, _ source: String) -> [Int?] {
        Alignment.assign(spoken: words(spoken), source: words(source), language: "fr")
    }

    func testAccentsAndApostrophes() {
        XCTAssertEqual(Alignment.assign(spoken: ["l'homme", "d'aujourd'hui", "ete"], source: ["L’homme", "d’aujourd’hui", "été"], language: "fr"), [0, 1, 2])
        XCTAssertEqual(Alignment.assign(spoken: ["l", "homme", "est", "la"], source: ["l'homme", "est", "là"], language: "fr"), [0, 0, 1, 2])
        XCTAssertEqual(Alignment.assign(spoken: ["aujourd'hui", "il"], source: ["aujourd", "hui", "il"], language: "fr"), [0, 2])
        XCTAssertEqual(Alignment.assign(spoken: ["qu'il", "est", "venu"], source: ["Qu’il", "est", "venu"], language: "fr"), [0, 1, 2])
        // English keeps its apostrophe rules: the possessive is dropped, no split
        XCTAssertEqual(Alignment.assign(spoken: ["john", "dont"], source: ["John's", "don’t"]), [0, 1])
    }

    func testFrenchNumberWordsMatchDigits() {
        XCTAssertEqual(assign("il a quatre vingt dix neuf ans", "il a 99 ans"), [0, 1, 2, 2, 2, 2, 3])
        XCTAssertEqual(assign("en mille neuf cent quatre vingt dix huit", "en 1998"), [0, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(assign("en deux mille vingt sept", "en 2027"), [0, 1, 1, 1, 1])
        XCTAssertEqual(assign("vingt et un jours", "21 jours"), [0, 0, 0, 1])
        XCTAssertEqual(assign("soixante et onze", "71"), [0, 0, 0])
        XCTAssertEqual(assign("quatre vingts euros", "80 euros"), [0, 0, 1])
        XCTAssertEqual(assign("deux cents", "200"), [0, 0])
        XCTAssertEqual(assign("quatre virgule deux millions", "4,2 millions"), [0, 0, 0, 1])
        XCTAssertEqual(assign("zéro virgule zéro cinq", "0,05"), [0, 0, 0, 0])
        XCTAssertEqual(assign("trois virgule quatorze", "3,14"), [0, 0, 0])
        XCTAssertEqual(assign("douze mille trois cent quarante cinq abonnés", "12345 abonnés"), [0, 0, 0, 0, 0, 0, 1])
    }

    func testFrenchNumbersWithUnitsOrdinalsAndTimes() {
        XCTAssertEqual(assign("quarante cinq euros par mois", "45€ par mois"), [0, 0, 0, 1, 2])
        XCTAssertEqual(assign("cinquante pour cent des gens", "50% des gens"), [0, 0, 0, 1, 2])
        XCTAssertEqual(assign("le deuxième étage", "le 2e étage"), [0, 1, 2])
        XCTAssertEqual(assign("le premier mai", "le 1er mai"), [0, 1, 2])
        XCTAssertEqual(assign("la première fois", "la 1re fois"), [0, 1, 2])
        XCTAssertEqual(assign("vingt et unième siècle", "21ème siècle"), [0, 0, 0, 1])
        XCTAssertEqual(assign("trois fois plus", "3x plus"), [0, 0, 1])
        // a number that does not equal the digits is not forced onto them
        XCTAssertEqual(assign("il a quatre vingt ans", "il a 99 ans"), [0, 1, nil, nil, 3])
    }

    func testEnglishNumberRulesStillEnglish() {
        XCTAssertEqual(Alignment.assign(spoken: ["forty", "five", "pounds"], source: ["£45"]), [0, 0, 0])
        XCTAssertEqual(Alignment.assign(spoken: ["quarante", "cinq"], source: ["45"]), [nil, nil])
    }

    // MARK: Timeline

    private func run(_ source: String, spoken: [SpokenWord]? = nil, duration: Double? = nil, language: String = "fr")
        -> (tokens: [Token], speakable: Speakable, timings: [WordTiming]) {
        let tokens = TextKit.tokenize(source)
        let speakable = Speakable.make(source, range: 0..<(source as NSString).length, lexicon: [:], language: language)
        let heard = spoken ?? TextKit.tokenize(speakable.text).enumerated().map { SpokenWord(text: $1.text, start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.3) }
        let total = duration ?? Double(heard.count) * 0.3
        return (tokens, speakable, Timeline.timings(chunkTokens: tokens, chunkTokenOffset: 0, speakable: speakable, spoken: heard,
                                                    offset: 0, chunkDuration: total, language: language))
    }

    private func at(_ t: WordTiming, _ start: Double, _ end: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.start, start, accuracy: 1e-9, "token \(t.token)", file: file, line: line)
        XCTAssertEqual(t.end, end, accuracy: 1e-9, "token \(t.token)", file: file, line: line)
    }

    private func assertInvariants(_ t: [WordTiming], tokens: Int, duration: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.map(\.token), Array(0..<tokens), file: file, line: line)
        for (i, x) in t.enumerated() {
            XCTAssertGreaterThanOrEqual(x.start, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(x.end, duration + 1e-9, file: file, line: line)
            XCTAssertLessThanOrEqual(x.start, x.end, file: file, line: line)
            if i > 0 { XCTAssertLessThanOrEqual(t[i - 1].end, x.start + 1e-9, "overlap before \(i)", file: file, line: line) }
        }
    }

    func testNumbersPercentAndContractionsThroughTheWholePath() {
        let source = "Il y a 4,2 millions d'habitants, soit 50 % de l’homme."
        let r = run(source)
        XCTAssertEqual(r.speakable.text, "Il y a quatre virgule deux millions d'habitants, soit cinquante pour cent de l’homme.")
        XCTAssertEqual(r.tokens.map(\.text), ["Il", "y", "a", "4", "2", "millions", "d'habitants", "soit", "50", "de", "l’homme"])
        assertInvariants(r.timings, tokens: r.tokens.count, duration: 14 * 0.3)
        // "quatre virgule deux" (words 3-5) is shared by the tokens "4" and "2", split by length
        XCTAssertEqual(r.timings[3].start, 0.9, accuracy: 1e-9)
        XCTAssertEqual(r.timings[3].end, r.timings[4].start, accuracy: 1e-9)
        XCTAssertEqual(r.timings[4].end, 1.8, accuracy: 1e-9)
        at(r.timings[5], 1.8, 2.1)    // millions
        at(r.timings[6], 2.1, 2.4)    // d'habitants
        at(r.timings[8], 2.7, 3.0)    // 50: "cinquante" ("pour cent" is the % sign)
        at(r.timings[9], 3.6, 3.9)    // de
        at(r.timings[10], 3.9, 4.2)   // l’homme
    }

    func testEngineSplittingAnElisionStillHighlightsTheToken() {
        let source = "J'aime l'homme."
        let spoken = [SpokenWord(text: "j", start: 0, end: 0.1), SpokenWord(text: "aime", start: 0.1, end: 0.4),
                      SpokenWord(text: "l", start: 0.4, end: 0.5), SpokenWord(text: "homme", start: 0.5, end: 0.9)]
        let r = run(source, spoken: spoken, duration: 1.0)
        XCTAssertEqual(r.tokens.map(\.text), ["J'aime", "l'homme"])
        XCTAssertEqual(r.timings, [WordTiming(token: 0, start: 0, end: 0.4), WordTiming(token: 1, start: 0.4, end: 0.9)])
    }

    func testDatesTemperaturesAndURLsThroughTheWholePath() {
        for source in ["Le 14 novembre 2027, il faisait 18°C à 11h20 (65 %).", "Écrivez à jean@exemple.fr ou voir https://exemple.org/a/b dès le 1er mai.",
                       "Coût : 45 €, soit 3,5 % de 12 345 € le 14/11/2027 à 6:45.", "« Où est l'été ? » a-t-elle demandé, 2 fois."] {
            let r = run(source)
            assertInvariants(r.timings, tokens: r.tokens.count, duration: Double(TextKit.tokenize(r.speakable.text).count) * 0.3)
            for (token, timing) in zip(r.tokens, r.timings) where r.speakable.covers(token.range) {
                XCTAssertGreaterThan(timing.end, timing.start, "\(token.text) in \(source)")
            }
        }
        let r = run("Il faisait 18°C ce 1er mai.")
        XCTAssertEqual(r.speakable.text, "Il faisait dix huit degrés Celsius ce premier mai.")
        // "C" (of °C) carries "degrés Celsius"; "18" carries "dix huit"; "1er" carries "premier"
        XCTAssertEqual(r.tokens.map(\.text), ["Il", "faisait", "18", "C", "ce", "1er", "mai"])
        at(r.timings[2], 0.6, 1.2)
        at(r.timings[3], 1.2, 1.8)
        at(r.timings[5], 2.1, 2.4)
    }

    func testFrenchFixtureThroughSpeakableAndTimeline() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reading-fr.txt").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let tokens = TextKit.tokenize(text)
        var checked = 0
        for chunk in TextKit.chunks(text, tokens: tokens) {
            let speakable = Speakable.make(text, range: chunk.range, lexicon: [:], language: "fr")
            XCTAssertFalse(speakable.text.contains(where: \.isNumber), "digits left in: \(speakable.text)")
            let heard = TextKit.tokenize(speakable.text)
            let spoken = heard.enumerated().map { SpokenWord(text: $1.text, start: Double($0) * 0.25, end: Double($0) * 0.25 + 0.2) }
            let chunkTokens = Array(tokens[chunk.tokens])
            let t = Timeline.timings(chunkTokens: chunkTokens, chunkTokenOffset: chunk.tokens.lowerBound, speakable: speakable, spoken: spoken,
                                     offset: 0, chunkDuration: Double(heard.count) * 0.25, language: "fr")
            XCTAssertEqual(t.count, chunkTokens.count)
            for (token, timing) in zip(chunkTokens, t) where speakable.covers(token.range) {
                XCTAssertGreaterThan(timing.end, timing.start, "\(token.text) in \(speakable.text)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }
}
