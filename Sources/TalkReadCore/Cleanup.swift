// Dictation clean-up: fillers, spoken punctuation, smart formatting (Formatting.swift), vocabulary replacement and
// near misses, capitalisation. Owned by WP2; formatting added by V-F.
import Foundation

public enum Cleanup {
    /// Order: spoken web addresses, fillers, spoken punctuation, spacing around punctuation, numbers, lists,
    /// vocabulary, vocabulary near misses, capitalisation, double spaces, trim. URLs, email addresses and vocabulary
    /// replacements are swapped for placeholders while the other rules run, so nothing inside them is altered (a
    /// vocabulary entry like "iOS" is not capitalised at the start of a sentence). `isWord` (the app's spell checker) keeps
    /// real words out of near-miss correction; explicit vocabulary entries always apply. `languages`: the dictation's, for
    /// the fillers (German "er" and Portuguese "um" are words, not fillers).
    public static func apply(_ raw: String, vocabulary: [String: String], removeFillers: Bool, languages: [String] = ["en"],
                             isWord: (String) -> Bool = { _ in false }) -> String {
        var protected: [String] = []
        func hold(_ text: String) -> String {
            protected.append(text)
            return "\(open)\(protected.count - 1)\(close)"
        }
        var text = raw.replacingOccurrences(of: "[\u{E000}-\u{E03F}]", with: "", options: .regularExpression)

        text = webForms(text)
        text = replaceAll(urlPattern, in: text) { hold(lowerHost($0[0])) }

        if removeFillers {
            // "que, euh, c'est" is "que c'est": a filler between two commas takes the first one with it (the pattern less
            // its "(?i)" and with its comma required).
            let filler = fillerPattern(languages)
            text = text.replacingOccurrences(of: ",(?=\(filler.dropFirst(4).dropLast(1)))", with: "", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: filler, with: "", options: .regularExpression)
        }

        // A spoken mark replaces one the recogniser already wrote ("John, comma" is "John,", not "John,,"; Parakeet v3
        // punctuates by itself). Line breaks, quotes and dashes keep what comes before them. Commands become placeholders
        // first, so a mark one command made is never taken for the recogniser's ("question mark exclamation mark" is "?!").
        let commands = spoken(languages)
        for (i, (pattern, replacement)) in commands.enumerated() {
            let before = ".,?!;:".contains(replacement) ? "(?:[.,!?;:][ \\t]*)?" : ""
            text = text.replacingOccurrences(of: "(?i)\(before)\\b(?:\(pattern))\\b[.,!?;:]?", with: Self.command(i), options: .regularExpression)
        }
        for (i, (_, replacement)) in commands.enumerated() { text = text.replacingOccurrences(of: Self.command(i), with: replacement) }
        text = text.replacingOccurrences(of: "[ \\t]+([.,?!:;])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]*\(closeQuote)", with: "\"", options: .regularExpression)
        text = text.replacingOccurrences(of: "\(openQuote)[ \\t]*", with: "\"", options: .regularExpression)
        text = numbers(text)
        text = lists(text)

        text = replaceVocabulary(in: text, vocabulary: vocabulary, hold: hold)
        text = correctTerms(in: text, terms: terms(vocabulary), isWord: isWord, hold: hold)
        text = text.replacingOccurrences(of: "<unk>", with: "")   // the recogniser's tag for a letter it cannot spell; never typed
        text = capitalised(text)

        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Restore placeholders (a held text never contains a placeholder, so one pass is enough).
        return replaceAll("\(open)\\d+\(close)", in: text) { match in
            let index = Int(match[0].dropFirst().dropLast()) ?? -1
            return protected.indices.contains(index) ? protected[index] : ""
        }
    }

    /// The spellings the vocabulary teaches (every "type instead" value, once), for recogniser biasing.
    public static func terms(_ vocabulary: [String: String]) -> [String] {
        Array(Set(vocabulary.values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    // MARK: Rules

    static let open = "\u{E000}", close = "\u{E001}"
    private static let openQuote = "\u{E010}", closeQuote = "\u{E011}"
    /// Web addresses, email addresses, and bare domains with a known ending and an optional path.
    private static let urlPattern = "(?i)\\b(?:https?://|www\\.)\\S*[^\\s.,;:!?)\\]\"']|[A-Za-z0-9._+-]+@\(domain)|\\b\(domain)(?:/[A-Za-z0-9._~%/-]*[A-Za-z0-9_~%/-])?"
    /// Hesitations to drop: the English ones whatever the language (people say "um" in French too), each language's own,
    /// less any that is a real word in one of the languages.
    static func fillerPattern(_ languages: [String]) -> String {
        let fillers: [String: [String]] = ["en": ["umm", "um", "uh", "erm", "er", "ah", "hmm"], "fr": ["euh", "heu"],
                                           "de": ["äh", "ähm"], "it": ["ehm", "uhm"]]
        let words: [String: Set<String>] = ["de": ["er", "um"], "pt": ["um"]]   // "Er kommt", "uns um acht", "Quero um café"
        var drop = (fillers["en"]! + languages.flatMap { fillers[$0] ?? [] }).filter { f in !languages.contains { words[$0]?.contains(f) == true } }
        // French "ah bon", "ah oui" are words; an "ah" before anything else is still a hesitation.
        if languages.contains("fr") { drop = drop.map { $0 == "ah" ? "ah(?!,?[ \\t]+(?:bon|oui|non|d['’]accord|bah|ça|là)\\b)" : $0 } }
        var seen = Set<String>()
        return "(?i)[ \\t]*\\b(?:\(drop.filter { seen.insert($0).inserted }.joined(separator: "|")))\\b,?"
    }

    /// Whole spoken phrases and what they become; the unambiguous French ones too when French is a dictation language.
    private static func spoken(_ languages: [String]) -> [(String, String)] {
        let english: [(String, String)] = [
            ("new paragraph", "\n\n"), ("new line", "\n"),
            ("full stop|period", "."), ("comma", ","), ("question mark", "?"),
            ("exclamation mark|exclamation point", "!"), ("semicolon", ";"), ("colon", ":"),
            ("open quote", openQuote), ("close quote", closeQuote), ("dash", " – ")
        ]
        guard languages.contains("fr") else { return english }
        // Only phrases that are hard to mean as prose. The bare ones ("virgule", "point final", "à la ligne", "nouveau
        // paragraphe", "deux points") are ordinary French ("la virgule est mal placée", "un nouveau paragraphe au contrat",
        // "le ballon sort à la ligne") and Parakeet v3 punctuates French well by itself, so they are left as words; so is a
        // mark named after an article ("un point d'interrogation plane sur le match").
        let noArticle = "(?<!\\b(?:un|le|du|au|ce|les|des|son|leur)[ \\t]{1,3})"
        return [("\(noArticle)point[ -]virgule", ";"), ("\(noArticle)point d['’]interrogation", "?"),
                ("\(noArticle)point d['’]exclamation", "!"),
                ("ouvrez les guillemets|ouvrir les guillemets", openQuote), ("fermez les guillemets|fermer les guillemets", closeQuote)]
            + english
    }

    /// The placeholder a spoken command stands as until all are found (private use, stripped from the input).
    private static func command(_ i: Int) -> String { String(Character(UnicodeScalar(0xE020 + i)!)) }

    /// Replaces every match with `transform(groups)`: index 0 is the whole match, an unmatched group is "".
    static func replaceAll(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func replaceVocabulary(in text: String, vocabulary: [String: String], hold: (String) -> String) -> String {
        var map: [String: String] = [:]
        for (key, value) in vocabulary {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !k.isEmpty { map[k] = value }
        }
        guard !map.isEmpty else { return text }
        let alternation = map.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        let pattern = "(?i)(?<![\\p{L}\\p{N}_])(?:\(alternation))(?![\\p{L}\\p{N}_])"
        return replaceAll(pattern, in: text) { match in
            let key = match[0].lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return map[key].map(hold) ?? match[0]
        }
    }

    /// Upper-cases the first letter of the text and of each sentence (after `. ? !` plus a space, or a newline).
    private static func capitalised(_ text: String) -> String {
        var out = "", next = true
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if next, ch.isLetter {
                out += ch.uppercased(); next = false; continue
            }
            out.append(ch)
            if ch == "\n" { next = true }
            else if ".?!".contains(ch) { next = i + 1 >= chars.count || chars[i + 1].isWhitespace }
            else if !ch.isWhitespace && !"\"'([“‘".contains(ch) { next = false }
        }
        return out
    }
}
