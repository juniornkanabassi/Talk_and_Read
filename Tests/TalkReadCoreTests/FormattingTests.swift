import XCTest
@testable import TalkReadCore

/// Smart formatting through Cleanup.apply, mostly on what the recognisers really wrote for the hard fixtures.
final class FormattingTests: XCTestCase {
    private func clean(_ s: String, _ vocabulary: [String: String] = [:]) -> String {
        Cleanup.apply(s, vocabulary: vocabulary, removeFillers: true)
    }

    func testEmailAddresses() {
        XCTAssertEqual(clean("Send the draft to junior at Kestrelco.com and copy legal at ulaw.ac.uk."),
                       "Send the draft to junior@kestrelco.com and copy legal@ulaw.ac.uk.")
        XCTAssertEqual(clean("mail junior at kestrelco dot com please"), "Mail junior@kestrelco.com please")
        XCTAssertEqual(clean("the report is at bbc.co.uk today"), "The report is at bbc.co.uk today", "a place, not a mailbox")
        XCTAssertEqual(clean("look at gov.uk first"), "Look at gov.uk first")
    }

    func testWebAddresses() {
        XCTAssertEqual(clean("The match report is on BBC.co.uk/slash sports slash football"), "The match report is on bbc.co.uk/sports/football")
        XCTAssertEqual(clean("it is on b b c dot co dot uk slash sport slash football."), "It is on bbc.co.uk/sport/football.")
        XCTAssertEqual(clean("I put a dot on the map"), "I put a dot on the map", "a dot chain needs a domain ending")
        XCTAssertEqual(clean("Their xG was 2.4. good"), "Their xG was 2.4. Good")
    }

    func testNumberCorrections() {
        XCTAssertEqual(clean("Book The Pitch for 7, actually 8, on Friday"), "Book The Pitch for 8 on Friday")
        XCTAssertEqual(clean("meet at 2 sorry 3pm"), "Meet at 3pm")
        XCTAssertEqual(clean("Kick-off is at 3 30pm."), "Kick-off is at 3:30pm.", "Parakeet v3 writes the time with a space")
        XCTAssertEqual(clean("Book 2 10pm slots."), "Book 2 10pm slots.", "a count before a time is not minutes")
        XCTAssertEqual(clean("Let's meet on Tuesday the fourteenth of March at 3 30pm."), "Let's meet on Tuesday 14 March at 3:30pm.")
        XCTAssertEqual(clean("It's on the twenty-first of June"), "It's on 21 June")
        XCTAssertEqual(clean("the thirty fifth of May"), "The thirty fifth of May", "no such day")
        XCTAssertEqual(clean("It's the second May bank holiday"), "It's the second May bank holiday")
        XCTAssertEqual(clean("We met during the first March I lived here"), "We met during the first March I lived here")
        XCTAssertEqual(clean("We went to 2 10pm screenings"), "We went to 2 10pm screenings")
        XCTAssertEqual(clean("Book the pitch for seven, actually 8, on Friday."), "Book the pitch for 8 on Friday.")
        XCTAssertEqual(clean("someone, actually one of them"), "Someone, actually one of them")
        XCTAssertEqual(clean("I actually enjoyed 2 of them"), "I actually enjoyed 2 of them")
    }

    func testMoneyAndPercentages() {
        XCTAssertEqual(clean("worth up to £10% of the fee"), "Worth up to 10% of the fee")
        XCTAssertEqual(clean("possession was 62 percent and 10 per cent"), "Possession was 62% and 10%")
        XCTAssertEqual(clean("The club paid £55000000 plus add-ons"), "The club paid £55 million plus add-ons")
        XCTAssertEqual(clean("a fee of 55 million pounds and 3 dollars"), "A fee of £55 million and $3")
        XCTAssertEqual(clean("4.5 million pounds, not 3.5 dollars"), "£4.5 million, not 3.5 dollars")
        XCTAssertEqual(clean("£2,000,000,000 deal"), "£2 billion deal")
    }

    func testTimes() {
        XCTAssertEqual(clean("Kickoff is a 8 p.m., and their position"), "Kickoff is a 8pm, and their position")
        XCTAssertEqual(clean("Let's meet at 330 p.m."), "Let's meet at 3:30pm.")
        XCTAssertEqual(clean("Take off is at 8 PM and"), "Take off is at 8pm and")
        XCTAssertEqual(clean("at 8 p.m. Then we eat"), "At 8pm. Then we eat")
        XCTAssertEqual(clean("at 3:30 pm sharp"), "At 3:30pm sharp")
        XCTAssertEqual(clean("I am here with 2 amps"), "I am here with 2 amps")
    }

    func testBritishDates() {
        XCTAssertEqual(clean("Let's meet on Tuesday, the 14th of March at 330 p.m."), "Let's meet on Tuesday 14 March at 3:30pm.")
        XCTAssertEqual(clean("on Tuesday, the 14 March at 3:30pm."), "On Tuesday 14 March at 3:30pm.")
        XCTAssertEqual(clean("the 1st of May"), "1 May")
    }

    func testSpokenLists() {
        XCTAssertEqual(clean("I need to do three things. First, finish the taught essay. Second, email the team. Third, renew my rail card."),
                       "I need to do three things.\n1. Finish the taught essay.\n2. Email the team.\n3. Renew my rail card.")
        XCTAssertEqual(clean("Number one, call Jon. Number two, book the pitch."), "1. Call Jon.\n2. Book the pitch.")
        XCTAssertEqual(clean("Firstly, it is late. Secondly, it is cold. Finally, it is dark."),
                       "1. It is late.\n2. It is cold.\n3. It is dark.")
        XCTAssertEqual(clean("First, I think so."), "First, I think so.", "one marker is not a list")
        XCTAssertEqual(clean("First, a. Third, b."), "First, a. Third, b.", "a gap is not a list")
        XCTAssertEqual(clean("the first, second and third goals"), "The first, second and third goals")
    }

    func testVocabularyNearMisses() {
        let v = ["Kestrelco": "Kestrelco", "Nkanabassi": "Nkanabassi", "Dembélé": "Dembélé", "Lord Atkin": "Lord Atkin",
                 "Donoghue": "Donoghue", "Vitinha": "Vitinha", "Caparo": "Caparo", "PSG": "PSG", "João Neves": "João Neves"]
        XCTAssertEqual(clean("email the kestralco team", v), "Email the Kestrelco team")
        XCTAssertEqual(clean("This is Junyung Kanabasi from Kestralko.", v), "This is Junyung Nkanabassi from Kestrelco.")
        XCTAssertEqual(clean("Dembele and Vitinho scored for psg", v), "Dembélé and Vitinha scored for PSG")
        XCTAssertEqual(clean("In Donahue vs. Stevenson, Lord Atkins set out", v), "In Donoghue vs. Stevenson, Lord Atkin set out")
        XCTAssertEqual(clean("with Joan Nevis behind them", v), "With João Neves behind them")
        XCTAssertEqual(clean("Nkana Bassi here", v), "Nkanabassi here")
    }

    func testNearMissesLeaveRealWordsAlone() {
        let v = ["Kestrelco": "Kestrelco", "Caparo": "Caparo"]
        XCTAssertEqual(clean("the football club", v), "The football club", "a shorter piece of the term")
        XCTAssertEqual(clean("a trip to Capri", v), "A trip to Capri")
        XCTAssertEqual(clean("kestrelco, ltd", v), "Kestrelco, ltd")
        XCTAssertEqual(clean("see kestrelco.com", v), "See kestrelco.com", "addresses are held")
    }

    /// Sol inspection 4 #4: with the app's dictionary check, a real word is never "corrected" into a taught one.
    func testNearMissesKeepDictionaryWords() {
        let dictionary: Set = ["please", "contact", "the", "team", "email", "desire", "joan", "nevis"]
        func clean(_ s: String, _ vocabulary: [String: String]) -> String {
            Cleanup.apply(s, vocabulary: vocabulary, removeFillers: true, isWord: { dictionary.contains($0.lowercased()) })
        }
        let v = ["contract": "contract", "Kestrelco": "Kestrelco", "Dembélé": "Dembélé", "Désiré": "Désiré", "João Neves": "João Neves"]
        XCTAssertEqual(clean("please contact the team", v), "Please contact the team")
        XCTAssertEqual(clean("email the kestralco team", v), "Email the Kestrelco team")
        XCTAssertEqual(clean("Dembele scored", v), "Dembélé scored", "not a word, only accents differ: the taught spelling")
        XCTAssertEqual(clean("desire is strong", v), "Desire is strong", "a real word is left alone even when only its accents differ")
        XCTAssertEqual(clean("with Joan Nevis", v), "With Joan Nevis", "every word real: left alone")
        XCTAssertEqual(clean("Joan Neves", v), "João Neves", "one unknown word: corrected")
        XCTAssertEqual(clean("please contact the team", ["contact": "contract"]), "Please contract the team", "an explicit heard-as entry still applies")
    }
}
