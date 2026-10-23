// Opt-in learning from the user's own corrections (off by default; nothing leaves the Mac): after a dictation is
// typed, the field is read again a few seconds later; words of the dictation the user re-spelt become "heard → typed"
// pairs, and a pair seen `threshold` times becomes a vocabulary suggestion. Pure logic: the app reads the field.
import Foundation

public enum AutoLearn {
    public struct Correction: Hashable, Codable, Sendable {
        public let heard: String
        public let typed: String
        public init(heard: String, typed: String) { self.heard = heard; self.typed = typed }
    }

    /// How many separate dictations must show the same correction before it is offered.
    public static let threshold = 2

    /// The re-spellings the user made inside the dictated text. `before` is the field's text right after the paste,
    /// with the dictation at `inserted` (UTF-16); `after` is the same field later. Edits that reach outside the
    /// dictation are ignored; inside it, each changed run of 1–3 words that looks like a re-spelling (similar letters,
    /// not a rewording) and is not a number, address or code is one correction.
    public static func corrections(before: String, after: String, inserted: Range<Int>) -> [Correction] {
        let b = before as NSString, a = after as NSString
        guard inserted.lowerBound >= 0, inserted.upperBound <= b.length, before != after else { return [] }
        var prefix = 0
        let shorter = min(b.length, a.length)
        while prefix < shorter, b.character(at: prefix) == a.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, b.character(at: b.length - 1 - suffix) == a.character(at: a.length - 1 - suffix) { suffix += 1 }
        guard prefix >= inserted.lowerBound, b.length - suffix <= inserted.upperBound else { return [] }
        let dictated = b.substring(with: NSRange(location: inserted.lowerBound, length: inserted.count))
        let edited = a.substring(with: NSRange(location: inserted.lowerBound, length: inserted.count + a.length - b.length))
        let heard = words(dictated), typed = words(edited)
        guard heard.count <= 300, typed.count <= 300 else { return [] }   // ponytail: O(n·m) diff, fine for dictations
        return hunks(heard, typed).compactMap { h, t in
            guard (1...3).contains(h.count), (1...3).contains(t.count) else { return nil }
            let c = Correction(heard: h.joined(separator: " "), typed: t.joined(separator: " "))
            return isRespelling(c) ? c : nil
        }
    }

    /// Records the corrections of one dictation (each pair once) and returns those that just reached the threshold.
    public static func record(_ found: [Correction], in counts: inout [String: Int]) -> [Correction] {
        Set(found).compactMap { c in
            let key = c.heard + " → " + c.typed
            counts[key, default: 0] += 1
            return counts[key] == threshold ? c : nil
        }.sorted { $0.typed < $1.typed }
    }

    // MARK: Rules

    /// Words without the punctuation around them.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Changed runs between two word lists (longest common subsequence; equal words anchor the runs).
    static func hunks(_ a: [String], _ b: [String]) -> [([String], [String])] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [([String], [String])] = [], i = 0, j = 0, ha: [String] = [], hb: [String] = []
        func flush() { if !ha.isEmpty || !hb.isEmpty { out.append((ha, hb)); ha = []; hb = [] } }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { flush(); i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { hb.append(b[j]); j += 1 }
            else { ha.append(a[i]); i += 1 }
        }
        flush()
        return out
    }

    /// A re-spelling of the same sound, not a new word: no digits, addresses or code in the typed form, and the
    /// letters (case and accents ignored) within half their length of each other.
    static func isRespelling(_ c: Correction) -> Bool {
        guard c.typed.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "@/\\_.:=<>{}[]#"))) == nil,
              c.heard != c.typed else { return false }
        let x = letters(c.heard), y = letters(c.typed)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(distance(x, y)) <= 0.5 * Double(max(x.count, y.count))
    }

    static func letters(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in a.indices {
            var diagonal = row[0]
            row[0] = i + 1
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = a[i] == b[j] ? diagonal : 1 + min(diagonal, above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }
}
