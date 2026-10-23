// Which language a text is in, for choosing the reading voice (PLAN 0.3.0 decisions 2 and 8).
import Foundation
import NaturalLanguage

public enum Language {
    /// `fr` when the text is clearly French, otherwise `en`: NaturalLanguage on up to the first 2,000 characters; French
    /// must be the top hypothesis at 0.7 or more, and the text needs at least 20 letters. One language per read.
    public static func detect(_ text: String) -> String {
        let head = text.prefix(2000)
        guard head.lazy.filter(\.isLetter).prefix(20).count == 20 else { return "en" }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(head))
        let top = recogniser.languageHypotheses(withMaximum: 1)
        return (top[.french] ?? 0) >= 0.7 ? "fr" : "en"
    }
}
