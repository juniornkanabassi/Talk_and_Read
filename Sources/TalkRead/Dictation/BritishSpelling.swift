// British spelling for recognisers trained on American English (Parakeet writes "neighbor", "organize"): a word the
// system's British dictionary rejects but its American one accepts is respelt by the usual pattern (-or → -our,
// -ize → -ise, -yze → -yse, -er → -re, -ense → -ence, -l- → -ll-, -ll → -l) when the British dictionary accepts the
// result. Words it cannot place by a pattern ("gray") are left alone; web and email addresses are skipped.
import AppKit

enum BritishSpelling {
    private static let patterns: [(String, String)] = [
        ("or(s|ed|ing|ite|ites|able|ful|less)?$", "our$1"), ("iz(e|es|ed|ing|ation|ations|er|ers)$", "is$1"),
        ("yz(e|es|ed|ing)$", "ys$1"), ("([^aeiou])er(s?)$", "$1re$2"), ("ense(s?)$", "ence$1"),
        ("([aeiou])l(ed|ing|er|ers)$", "$1ll$2"), ("ll(ment|ments)?$", "l$1")
    ]

    @MainActor static func apply(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        func accepted(_ word: String, _ language: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}@./])[A-Za-z]{4,}(?![\\p{L}@/]|\\.[A-Za-z])") else { return text }
        let out = NSMutableString(string: text)
        for m in regex.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let word = out.substring(with: m.range)
            guard !accepted(word, "en_GB"), accepted(word, "en_US") else { continue }
            for (pattern, template) in patterns {
                let british = word.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
                if british != word, accepted(british, "en_GB") { out.replaceCharacters(in: m.range, with: british); break }
            }
        }
        return out as String
    }
}
