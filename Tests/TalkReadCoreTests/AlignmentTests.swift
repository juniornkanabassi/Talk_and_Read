import XCTest
@testable import TalkReadCore

final class AlignmentTests: XCTestCase {
    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    private func assign(_ spoken: String, _ source: String) -> [Int?] { Alignment.assign(spoken: words(spoken), source: words(source)) }

    func testIdentityAndCaseAndPunctuation() {
        XCTAssertEqual(assign("the quick brown fox", "the quick brown fox"), [0, 1, 2, 3])
        XCTAssertEqual(Alignment.assign(spoken: ["hello", "world"], source: ["Hello,", "WORLD!"]), [0, 1])
        XCTAssertEqual(Alignment.assign(spoken: ["cafe", "naive"], source: ["Café", "naïve"]), [0, 1])
        XCTAssertEqual(Alignment.assign(spoken: ["john", "dont"], source: ["John's", "don’t"]), [0, 1])
        XCTAssertEqual(Alignment.assign(spoken: [], source: ["a"]), [])
        XCTAssertEqual(Alignment.assign(spoken: ["a"], source: []), [nil])
    }

    func testInsertionsAndDeletions() {
        // the engine says extra words
        XCTAssertEqual(assign("the very quick brown fox", "the quick brown fox"), [0, nil, 1, 2, 3])
        XCTAssertEqual(assign("hello there the quick brown fox ok", "the quick brown fox"), [nil, nil, 0, 1, 2, 3, nil])
        // the engine drops words
        XCTAssertEqual(assign("the brown fox", "the quick brown fox"), [0, 2, 3])
        XCTAssertEqual(assign("quick brown", "the quick brown fox"), [1, 2])
        // a different word is just two gaps
        XCTAssertEqual(assign("the slow brown fox", "the quick brown fox"), [0, nil, 2, 3])
    }

    func testRepeatedWords() {
        XCTAssertEqual(assign("the the the", "the the the"), [0, 1, 2])
        XCTAssertEqual(assign("no no no way", "no no no way"), [0, 1, 2, 3])
        XCTAssertEqual(assign("go go go", "go go"), [0, 1, nil])
        XCTAssertEqual(assign("a b a b a b", "a b a b a b"), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(assign("very very good", "very good"), [0, nil, 1])
    }

    func testNumbers() {
        XCTAssertEqual(assign("twenty one", "21"), [0, 0])
        XCTAssertEqual(assign("I have twenty one apples", "I have 21 apples"), [0, 1, 2, 2, 3])
        XCTAssertEqual(assign("two point five", "2.5"), [0, 0, 0])
        XCTAssertEqual(assign("nineteen ninety nine", "1999"), [0, 0, 0])
        XCTAssertEqual(assign("twenty twenty six", "2026"), [0, 0, 0])
        XCTAssertEqual(assign("two thousand and twenty six", "2026"), [0, 0, 0, 0, 0])
        XCTAssertEqual(assign("nineteen oh five", "1905"), [0, 0, 0])
        XCTAssertEqual(assign("one hundred and twenty three", "123"), [0, 0, 0, 0, 0])
        XCTAssertEqual(assign("one million two hundred thousand", "1,200,000"), [0, 0, 0, 0, 0])
        XCTAssertEqual(assign("twenty first", "21st"), [0, 0])
        XCTAssertEqual(assign("the third time", "the 3rd time"), [0, 1, 2])
        XCTAssertEqual(assign("five times", "5x"), [0, 0])
        XCTAssertEqual(assign("five times three is fifteen", "5 x 3 is 15"), [0, 1, 2, 3, 4])
        XCTAssertEqual(assign("ten percent", "10%"), [0, 0])
        // spoken digits equal digit tokens directly
        XCTAssertEqual(assign("in 1999 we", "in 1999 we"), [0, 1, 2])
        // a wrong value does not match
        XCTAssertEqual(assign("twenty two", "21"), [nil, nil])
    }

    func testDates() {
        XCTAssertEqual(assign("twenty first of october", "21 October"), [0, 0, nil, 1])
        XCTAssertEqual(assign("the twenty first of october", "21 October"), [nil, 0, 0, nil, 1])
        XCTAssertEqual(assign("on the third of march twenty twenty seven", "on 3 March 2027"), [0, nil, 1, nil, 2, 3, 3, 3])
        XCTAssertEqual(assign("march fourteenth", "March 14th"), [0, 1])
    }

    func testInitialisms() {
        XCTAssertEqual(assign("f b i", "FBI"), [0, 0, 0])
        XCTAssertEqual(assign("fbi", "FBI"), [0])
        XCTAssertEqual(assign("the n h s said", "the NHS said"), [0, 1, 1, 1, 2])
        XCTAssertEqual(assign("b b c news", "BBC news"), [0, 0, 0, 1])
        // an initialism the tokenizer split into letters
        XCTAssertEqual(assign("fbi agent", "F B I agent"), [0, 3])
        XCTAssertEqual(assign("f b i agent", "F B I agent"), [0, 1, 2, 3])
    }

    func testHyphenParts() {
        // the tokenizer splits at hyphens, so parts align one to one
        XCTAssertEqual(assign("state of the art design", "state of the art design"), [0, 1, 2, 3, 4])
        // as one compound source word, the parts all belong to it
        XCTAssertEqual(Alignment.assign(spoken: ["a", "state", "of", "the", "art", "tool"], source: ["a", "state-of-the-art", "tool"]), [0, 1, 1, 1, 1, 2])
        // and a hyphenated spoken word against split tokens
        XCTAssertEqual(Alignment.assign(spoken: ["twenty-one", "dogs"], source: ["21", "dogs"]), [0, 1])
        XCTAssertEqual(Alignment.assign(spoken: ["well-known", "fact"], source: ["well", "known", "fact"]), [0, 2])
    }

    func testCurrency() {
        XCTAssertEqual(assign("it costs forty five pounds today", "it costs £45 today"), [0, 1, 2, 2, 2, 3])
        XCTAssertEqual(assign("it costs forty five pounds today", "it costs 45 today"), [0, 1, 2, 2, 2, 3])
        XCTAssertEqual(assign("five dollars", "$5"), [0, 0])
        XCTAssertEqual(assign("a few pounds", "a few pounds"), [0, 1, 2])
        XCTAssertEqual(assign("45 pounds", "45 pounds"), [0, 1])
        XCTAssertEqual(assign("forty five pounds", "45 pounds"), [0, 0, 1])
        XCTAssertEqual(assign("three point five million pounds", "£3.5 million"), [0, 0, 0, 1, nil])
    }

    /// Sentences of the reading fixture as a neural engine would normalise them: each spoken word with the source token
    /// it must land on ("-" = no source token).
    func testFixtureSentencesAsAnEngineSaysThem() {
        let cases: [(source: String, said: [(String, String)])] = [
            ("The harbour town of Marlowe Quay woke slowly on 14 March 2027.",
             [("the", "The"), ("harbour", "harbour"), ("town", "town"), ("of", "of"), ("marlowe", "Marlowe"), ("quay", "Quay"), ("woke", "woke"),
              ("slowly", "slowly"), ("on", "on"), ("fourteen", "14"), ("march", "March"), ("twenty", "2027"), ("twenty", "2027"), ("seven", "2027")]),
            ("By 6:45 a.m. the first ferry had left, carrying 212 passengers",
             [("by", "By"), ("six", "6"), ("forty", "45"), ("five", "45"), ("a", "a"), ("m", "m"), ("the", "the"), ("first", "first"), ("ferry", "ferry"),
              ("had", "had"), ("left", "left"), ("carrying", "carrying"), ("two", "212"), ("hundred", "212"), ("and", "212"), ("twelve", "212"), ("passengers", "passengers")]),
            ("the new NHS liaison, Dr. Priya Raman, spread out",
             [("the", "the"), ("new", "new"), ("n", "NHS"), ("h", "NHS"), ("s", "NHS"), ("liaison", "liaison"), ("doctor", "-"), ("priya", "Priya"),
              ("raman", "Raman"), ("spread", "spread"), ("out", "out")]),
            ("Approve a 3.5 million pound budget for the lifeboat station.",
             [("approve", "Approve"), ("a", "a"), ("three", "3"), ("point", "-"), ("five", "5"), ("million", "million"), ("pound", "pound"),
              ("budget", "budget"), ("for", "for"), ("the", "the"), ("lifeboat", "lifeboat"), ("station", "station")]),
            ("Replace forty-two broken streetlights along the old high-street.",
             [("replace", "Replace"), ("forty", "forty"), ("two", "two"), ("broken", "broken"), ("streetlights", "streetlights"), ("along", "along"),
              ("the", "the"), ("old", "old"), ("high", "high"), ("street", "street")]),
            ("Mrs. Okafor paid £45 on the 21st of October at 9 p.m.",
             [("missus", "-"), ("okafor", "Okafor"), ("paid", "paid"), ("forty", "45"), ("five", "45"), ("pounds", "45"), ("on", "on"), ("the", "the"),
              ("twenty", "21st"), ("first", "21st"), ("of", "of"), ("october", "October"), ("at", "at"), ("nine", "9"), ("p", "p"), ("m", "m")]),
        ]
        for (source, said) in cases {
            let tokens = TextKit.tokenize(source).map(\.text)
            let got = Alignment.assign(spoken: said.map(\.0), source: tokens)
            let landed = got.map { $0.map { tokens[$0] } ?? "-" }
            XCTAssertEqual(landed, said.map(\.1), source)
        }
    }

    func testDriftAndLongNumberHeavyText() {
        // the first half is plain words, the second says three words for each token: the band follows the path
        var source: [String] = [], spoken: [String] = []
        for i in 0..<400 { source.append("w\(i)"); spoken.append("w\(i)") }
        var expected = [Int?](repeating: nil, count: 400)
        for i in 0..<400 { expected[i] = i }
        for i in 0..<400 {
            let two = i % 99 + 1
            source.append("19\(String(format: "%02d", two))")
            let tail = two < 10 ? ["oh", ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][two]] : Self.twoDigit(two).split(separator: " ").map(String.init)
            spoken += ["nineteen"] + tail
            let first = expected.count
            expected += Array(repeating: 400 + i, count: 1 + tail.count)
            XCTAssertEqual(expected.count - first, 1 + tail.count)
        }
        let got = Alignment.assign(spoken: spoken, source: source)
        XCTAssertEqual(got.count, expected.count)
        XCTAssertEqual(zip(got, expected).filter { $0 != $1 }.count, 0)
    }

    private static func twoDigit(_ n: Int) -> String {
        let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        return n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : " " + ones[n % 10])
    }

    func testFiveThousandWordsUnder200ms() {
        var rng = SplitMix(seed: 7)
        let vocabulary = (0..<300).map { "word\($0)" }
        let source = (0..<5000).map { _ in vocabulary[Int(rng.next() % 300)] }
        var spoken: [String] = []   // drop 3 %, insert 3 %
        var expected: [Int?] = []
        for (i, w) in source.enumerated() {
            let r = rng.next() % 100
            if r < 3 { continue }
            if r > 96 { spoken.append("extra"); expected.append(nil) }
            spoken.append(w); expected.append(i)
        }
        let start = Date()
        let got = Alignment.assign(spoken: spoken, source: source)
        let elapsed = Date().timeIntervalSince(start)
        print("ALIGNMENT 5000 words (\(spoken.count) spoken): \(Int(elapsed * 1000)) ms")
        XCTAssertLessThan(elapsed, 0.2)
        let wrong = zip(got, expected).filter { $0 != $1 }.count
        XCTAssertLessThan(wrong, 50, "a repeated word can legitimately land on an equal neighbour; most must be exact")
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
