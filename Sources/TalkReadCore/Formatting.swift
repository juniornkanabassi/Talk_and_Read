// Smart formatting for dictation (V-F), run by Cleanup.apply: spoken web addresses, number corrections ("7, actually
// 8"), money, percentages, times and British dates, spoken lists as numbered lines, and near-miss spellings of the
// vocabulary's words. Every rule is narrow on purpose: a missed format costs one edit, a wrong one costs trust.
import Foundation

extension Cleanup {
    // MARK: Web addresses

    static let tlds = "com|org|net|io|ai|dev|co|uk|fr|de|eu|edu|gov|ac|tv|me|info|ie|us|ca|au|es|it|nl|be|ch"
    static let domain = "[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.(?:\(tlds))(?![A-Za-z0-9-])"

    /// "footballco dot com" → "footballco.com", "b b c.co.uk" → "bbc.co.uk", "bbc.co.uk slash sport" →
    /// "bbc.co.uk/sport", "junior at footballco.com" → "junior@footballco.com". A "dot" chain joins only when it ends in
    /// a known domain ending; "at" joins only after a name-like word (not "is at", "look at", "site at").
    static func webForms(_ input: String) -> String {
        var text = replaceAll("(?i)\\b[a-z0-9-]+(?:\\s+dot\\s+[a-z0-9-]+)+\\b", in: input) { m in
            let joined = m[0].replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: [.regularExpression, .caseInsensitive])
            let last = joined.split(separator: ".").last.map { $0.lowercased() } ?? ""
            return tlds.split(separator: "|").contains(Substring(last)) ? joined : m[0]
        }
        text = replaceAll("(?i)\\b((?:[a-z] ){1,6}[a-z])(?=\\.(?:[a-z0-9-]+\\.)*(?:\(tlds))\\b)", in: text) { $0[1].replacingOccurrences(of: " ", with: "") }
        text = replaceAll("(?i)\\b(\(domain))((?:\\s*/\\s*(?:slash\\s+)?|\\s+slash\\s+)[A-Za-z0-9-]+)+", in: text) { m in
            m[0].replacingOccurrences(of: "\\s*/\\s*(?:slash\\s+)?|\\s+slash\\s+", with: "/", options: [.regularExpression, .caseInsensitive])
        }
        text = replaceAll("(?i)\\b([a-z0-9][a-z0-9._+-]*)\\s+at\\s+(\(domain))", in: text) { m in
            notMailbox.contains(m[1].lowercased()) ? m[0] : m[1].lowercased() + "@" + m[2].lowercased()
        }
        return text
    }

    /// Words that put "X at example.com" somewhere rather than make it an address.
    static let notMailbox: Set<String> = ["is", "are", "was", "were", "be", "been", "it", "its", "it's", "me", "us", "them", "him", "her",
                                          "you", "here", "there", "look", "looked", "looking", "site", "page", "website", "online",
                                          "available", "live", "found", "based", "hosted", "posted", "published", "details", "more",
                                          "now", "up", "out", "in", "on", "go", "went", "visit", "check", "see", "read", "stay", "stayed"]

    /// A bare address held for protection: the host lower-cased ("BBC.co.uk/sport" → "bbc.co.uk/sport").
    static func lowerHost(_ address: String) -> String {
        if address.contains("@") { return address.lowercased() }
        guard !address.lowercased().hasPrefix("http"), !address.lowercased().hasPrefix("www.") else { return address }
        let parts = address.split(separator: "/", maxSplits: 1)
        return parts[0].lowercased() + (parts.count > 1 ? "/" + parts[1] : "")
    }

    // MARK: Numbers

    static let months = "January|February|March|April|May|June|July|August|September|October|November|December"

    /// "7, actually 8" (or "seven, actually 8") → "8"; "£10%" → "10%"; "10 per cent" → "10%"; "55 million pounds" → "£55 million";
    /// "£55000000" → "£55 million"; "8 p.m." → "8pm"; "330 p.m." → "3:30pm"; "the 14th of March" → "14 March".
    static func numbers(_ input: String) -> String {
        let small = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
        let number = "(?:\\d+(?:[.,:]\\d+)*|\\b(?:\(small))\\b)(?:\\s?[aApP]\\.?\\s?[mM]\\b\\.?)?"
        var text = input.replacingOccurrences(
            of: "\\b(\(number))\\s*,?\\s+(?:actually|sorry|I mean|no wait|make that|or rather)\\s*,?\\s+(\(number))(?:\\s*,(?=\\s))?",
            with: "$2", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "[£$€](\\d[\\d,.]*\\s?%)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\b(\\d[\\d,.]*)\\s?(?:per ?cent|percent)\\b", with: "$1%", options: [.regularExpression, .caseInsensitive])
        for (word, sign) in [("pounds?", "£"), ("dollars?", "$"), ("euros?", "€")] {
            // Whole amounts, or decimals with a scale ("4.5 million"): "3.5 dollars" stays (it would want "$3.50").
            text = text.replacingOccurrences(of: "(?<![\\d.,])\\b(\\d[\\d,]*(?:\\.\\d+\\s(?:thousand|million|billion|trillion)|\\s(?:thousand|million|billion|trillion))?)\\s\(word)\\b",
                                             with: "\(sign)$1", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "([£$€]\\d{1,3})(?:,?000){3}\\b", with: "$1 billion", options: .regularExpression)
        text = text.replacingOccurrences(of: "([£$€]\\d{1,3})(?:,?000){2}\\b", with: "$1 million", options: .regularExpression)
        // Times: "3:30 P.M." / "3:30 PM" / "330 p.m." → "3:30pm"; a full stop the abbreviation swallowed is put back.
        // (Case spelt out, not (?i): "[A-Z]" in the full-stop test must stay upper case.)
        text = text.replacingOccurrences(of: "\\b(1[0-2]|[1-9])([0-5]\\d)(\\s?[aApP]\\.?\\s?[mM]\\b)", with: "$1:$2$3", options: .regularExpression)
        text = replaceAll("\\b(\\d{1,2}(?::\\d{2})?)\\s?([aApP])\\.?\\s?[mM]\\b(?:\\.(?!\\s*$|\\s+[A-Z]|\\s*\\n))?", in: text) {
            $0[1] + $0[2].lowercased() + "m"
        }
        // British dates: "the 14th of March" / "the 14 March" → "14 March"; "Tuesday, 14 March" → "Tuesday 14 March".
        text = text.replacingOccurrences(of: "\\bthe (\\d{1,2})(?:st|nd|rd|th)?(?: of)? (\(months))\\b", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), (\\d{1,2} (?:\(months)))\\b",
                                         with: "$1 $2", options: .regularExpression)
        return text
    }

    // MARK: Lists

    static let ordinals = ["first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4,
                           "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]

    /// "… things. First, finish the essay. Second, email Jon." → "… things.\n1. Finish the essay.\n2. Email Jon." Only
    /// when the markers open sentences and run 1, 2 (, 3 …) without a gap; "lastly" or "finally" may end the run.
    static func lists(_ text: String) -> String {
        let pattern = "(?i)(^|[.!?:;]\\s+|\\n)(firstly|first|secondly|second|thirdly|third|fourthly|fourth|fifth|sixth|seventh|eighth|ninth|tenth|lastly|finally|number (?:one|two|three|four|five|six|seven|eight|nine|ten))\\s*,\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let spoken = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        var run: [(NSTextCheckingResult, Int)] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 2)).lowercased()
            let n = ordinals[word] ?? spoken[word.replacingOccurrences(of: "number ", with: "")]
                ?? (word == "lastly" || word == "finally" ? (run.last?.1).map { $0 + 1 } : nil)
            guard let n else { continue }
            if n == (run.last?.1 ?? 0) + 1 { run.append((m, n)) } else if n == 1 { if run.count < 2 { run = [(m, 1)] } }
        }
        guard run.count >= 2 else { return text }
        var out = text as NSString
        for (m, n) in run.reversed() {
            let lead = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out = out.replacingCharacters(in: m.range, with: lead + "\n\(n). ") as NSString
        }
        return (out as String).replacingOccurrences(of: "^\\n", with: "", options: .regularExpression)
    }

    // MARK: Vocabulary near misses

    /// Near misses of the vocabulary's spellings become the spelling: "Footbalco" → "Footballco", "Nkana Bassi" →
    /// "Nkanabassi", "Dembele" → "Dembélé". Letters are compared with case and accents ignored, over windows of one word
    /// fewer to one more than the term; a window within a quarter of the term's letters is replaced, closest first.
    /// Terms under five letters only match exactly, and a window that is a shorter piece of the term ("football" in
    /// "Footballco") is left alone.
    /// ponytail: no dictionary check, so a real word within a quarter of a long vocabulary word is replaced; pass an
    /// isWord check from the app (NSSpellChecker) if that ever bites.
    static func correctTerms(in text: String, terms: [String], hold: (String) -> String) -> String {
        guard !terms.isEmpty, let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’-]*") else { return text }
        let ns = text as NSString
        let words = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var found: [(range: NSRange, term: String, distance: Int)] = []
        for term in terms {
            let target = folded(term)
            guard target.count >= 5 else { continue }
            let size = term.split(whereSeparator: \.isWhitespace).count
            for width in max(1, size - 1)...(size + 1) where width <= words.count {
                for start in 0...(words.count - width) {
                    let first = words[start], last = words[start + width - 1]
                    let range = NSRange(location: first.location, length: last.location + last.length - first.location)
                    let piece = ns.substring(with: range)
                    let joined = words[start..<start + width].map { ns.substring(with: $0) }.joined(separator: " ")
                    guard piece != term, piece == joined, !touchesPlaceholder(range, in: ns) else { continue }
                    let key = folded(piece)
                    if key.count < target.count, String(target).contains(String(key)) { continue }
                    let d = AutoLearn.distance(key, target)
                    if d <= target.count / 4 { found.append((range, term, d)) }
                }
            }
        }
        var taken: [NSRange] = [], chosen: [(NSRange, String)] = []
        for f in found.sorted(by: { ($0.distance, -$0.range.length) < ($1.distance, -$1.range.length) })
        where !taken.contains(where: { NSIntersectionRange($0, f.range).length > 0 }) {
            taken.append(f.range)
            chosen.append((f.range, f.term))
        }
        var out = ns
        for (range, term) in chosen.sorted(by: { $0.0.location > $1.0.location }) {
            out = out.replacingCharacters(in: range, with: hold(term)) as NSString
        }
        return out as String
    }

    /// A held text's placeholder ("\u{E000}3\u{E001}") is next to or inside the range: its digit is not a word.
    static func touchesPlaceholder(_ range: NSRange, in ns: NSString) -> Bool {
        let from = max(0, range.location - 1), to = min(ns.length, range.location + range.length + 1)
        return ns.substring(with: NSRange(location: from, length: to - from)).contains { $0 == "\u{E000}" || $0 == "\u{E001}" }
    }

    static func folded(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber })
    }
}
