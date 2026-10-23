// Which language a text is in, for choosing the reading voice (PLAN 0.3.0 decisions 2 and 8, revised 23 Oct by the lead).
import Foundation
import NaturalLanguage

public enum Language {
    /// `fr` when sentences whose top hypothesis is French hold at least 60 % of the letters in the first 2,000 characters
    /// and the text has at least 20 letters, otherwise `en`. So one French sentence in an English text stays English. One
    /// language per read.
    public static func detect(_ text: String) -> String {
        let head = String(text.prefix(2000))
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = head
        var french = 0, total = 0
        tokenizer.enumerateTokens(in: head.startIndex..<head.endIndex) { range, _ in
            let sentence = head[range]
            let letters = sentence.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            guard letters > 0 else { return true }
            total += letters
            if NLLanguageRecognizer.dominantLanguage(for: String(sentence)) == .french { french += letters }
            return true
        }
        return total >= 20 && Double(french) >= 0.6 * Double(total) ? "fr" : "en"
    }
}
