// British spelling for recognisers trained on American English (Parakeet writes "neighbor", "organize"): a word the
// system's British dictionary rejects but its American one accepts is respelt by the usual pattern (-or → -our,
// -ize → -ise, -yze → -yse, -er → -re, -ense → -ence, -l- → -ll-, -ll → -l) when the British dictionary accepts the
// result. Words it cannot place by a pattern ("gray") are left alone; web and email addresses are skipped.
import AppKit
import ObjCExceptionCatch
import TalkReadCore

enum BritishSpelling {
    private static let patterns: [(String, String)] = [
        ("or(s|ed|ing|ite|ites|able|ful|less)?$", "our$1"), ("iz(e|es|ed|ing|ation|ations|er|ers)$", "is$1"),
        ("yz(e|es|ed|ing)$", "ys$1"), ("([^aeiou])er(s?)$", "$1re$2"), ("ense(s?)$", "ence$1"),
        ("([aeiou])l(ed|ing|er|ers)$", "$1ll$2"), ("ll(ment|ments)?$", "l$1")
    ]

    /// Only the sentences confidently English in a dictation in several languages (a French "favorite" is not respelt,
    /// even in a sentence too short to place), and in them no word another chosen language's dictionary accepts ("ma
    /// favorite" inside an English sentence; the price is an English "favorite" left as it is while French is on).
    @MainActor static func apply(_ text: String, languages: [String]) -> String {
        guard languages.contains("en") else { return text }
        guard languages.count > 1 else { return apply(text) }
        let others = DictationController.dictionaries(for: languages.filter { $0 != "en" })
        return Language.runs(text, among: languages, inherit: false)
            .map { $0.language == "en" ? apply(String($0.text), keepingWordsOf: others) : String($0.text) }.joined()
    }

    /// Whether the system dictionary for `language` accepts `word`; nil when the spell server did not answer. It raises
    /// NSXPCSpellServerTimeoutException then, and an exception unwinding through Swift and SwiftUI froze the app for
    /// good (work Mac, 7 Nov 2026).
    @MainActor static func spelledRight(_ word: String, _ language: String) -> Bool? {
        var found = NSNotFound
        let failed = TRCatchException {
            found = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location
        }
        return failed == nil ? found == NSNotFound : nil
    }

    @MainActor static func apply(_ text: String, keepingWordsOf others: [String] = []) -> String {
        let accepted = spelledRight
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}@./])[A-Za-z]{4,}(?![\\p{L}@/]|\\.[A-Za-z])") else { return text }
        let out = NSMutableString(string: text)
        for m in regex.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let word = out.substring(with: m.range)
            // An unanswered check (nil) leaves the word as dictated.
            guard accepted(word, "en_GB") == false, accepted(word, "en_US") == true,
                  !others.contains(where: { accepted(word, $0) != false }) else { continue }
            for (pattern, template) in patterns {
                let british = word.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
                if british != word, accepted(british, "en_GB") == true { out.replaceCharacters(in: m.range, with: british); break }
            }
        }
        return out as String
    }
}
