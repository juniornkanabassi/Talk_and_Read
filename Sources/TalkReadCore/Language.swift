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

    /// Dictation's text cut into runs of one language each, so the clean-up can treat each in its own language (British
    /// spelling only on English, for instance). Each sentence is classified among `languages` alone; one with fewer than
    /// 12 letters, or whose best guess is under 60 %, takes the language of the sentence before it (at the start, of the
    /// first one placed; with none placed, `fallback`, else the first of `languages`). With `inherit` false such a sentence
    /// is labelled "" (unknown) instead, for a rule that must not touch the wrong language ("Ma favorite." after an English
    /// sentence is not respelt). Neighbours in the same language merge, and the runs joined give back `text` exactly.
    public static func runs(_ text: String, among languages: [String], fallback: String? = nil, inherit: Bool = true) -> [(text: Substring, language: String)] {
        let fallback = fallback.flatMap { languages.contains($0) ? $0 : nil } ?? languages.first ?? "en"
        guard languages.count > 1, !text.isEmpty else { return text.isEmpty ? [] : [(text[...], fallback)] }   // one language: certain
        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = languages.map { NLLanguage(rawValue: $0) }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var starts: [String.Index] = [], guesses: [String?] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            starts.append(range.lowerBound)
            guard sentence.reduce(0, { $0 + ($1.isLetter ? 1 : 0) }) >= 12 else { guesses.append(nil); return true }
            recogniser.reset()
            recogniser.processString(sentence)
            let best = recogniser.languageHypotheses(withMaximum: 1).first
            guesses.append(best.flatMap { $0.value >= 0.6 ? $0.key.rawValue : nil })
            return true
        }
        guard !starts.isEmpty else { return [(text[...], inherit ? fallback : "")] }
        starts[0] = text.startIndex                                  // leading spaces belong to the first sentence
        var current = guesses.compactMap { $0 }.first ?? fallback
        var out: [(text: Substring, language: String)] = []
        for (i, start) in starts.enumerated() {
            if let g = guesses[i] { current = g } else if !inherit { current = "" }
            let end = i + 1 < starts.count ? starts[i + 1] : text.endIndex
            if let last = out.last, last.language == current {
                out[out.count - 1] = (text[last.text.startIndex..<end], current)
            } else {
                out.append((text[start..<end], current))
            }
        }
        return out
    }
}
