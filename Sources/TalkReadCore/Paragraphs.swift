// Paragraphs for long dictations (F-A, PLAN 0.6.0): a break before a sentence that follows a real pause, a forced break
// when a run of sentences has none, and a full stop at the end. Pure; the recogniser supplies the pauses. A dictation
// under `minWords` is returned exactly as it came.
import Foundation

public enum Paragraphs {
    // ponytail: constants from the plan, not tuned on Junior's own speech yet; adjust after live use.
    /// Shorter dictations (talking to an assistant) are left alone.
    static let minWords = 60
    /// A pause of at least this many seconds before a sentence starts a new paragraph.
    static let pauseBreak = 1.0
    /// With no such pause for this many sentences, a break is forced at the longest pause among sentences 3 to 6.
    static let forceAfter = 5

    /// The silence before a sentence (after the first), with that sentence's first word so it can be found again once
    /// Cleanup has reshaped the text.
    public struct Pause: Equatable, Sendable {
        public var word: String
        public var seconds: Double
        public init(word: String, seconds: Double) { self.word = word; self.seconds = seconds }
    }

    private static let terminator = "[.?!][\"'”’)\\]]*"

    /// The pauses before the sentences of a timed word list: a sentence starts after a word ending in `. ? !`.
    public static func pauses(of words: [(text: String, start: Double, end: Double)]) -> [Pause] {
        words.indices.dropFirst().compactMap { i in
            words[i - 1].text.range(of: "\(terminator)$", options: .regularExpression) == nil ? nil
                : Pause(word: key(words[i].text), seconds: max(0, words[i].start - words[i - 1].end))
        }
    }

    /// `text` with `\n\n` before sentences that follow a pause of a second or more, and a forced break in a run of
    /// sentences with none. Never inside a formatted list line, never next to a line break already there (spoken "new
    /// paragraph" or "new line"), never leaving a one-sentence paragraph at the end of a stretch. A sentence after a break
    /// starts with a capital. The last sentence gets a full stop when it has no end mark.
    public static func split(_ text: String, pauses: [Pause] = []) -> String {
        guard text.split(whereSeparator: \.isWhitespace).count >= minWords else { return text }
        var next = 0, first = true
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let list = line.range(of: "^\\d{1,3}\\. ", options: .regularExpression)
            let parts = sentences(list.map { String(line[$0.upperBound...]) } ?? line)
            // Cleanup can add or drop sentence boundaries ("3 p.m.", fillers); a pause is taken from the next few entries
            // whose first word matches, else it is unknown (0).
            var gaps: [Double] = []
            for part in parts {
                defer { first = false }
                let hit = first ? nil : pauses[next...].prefix(3).firstIndex { $0.word == key(part) }
                gaps.append(hit.map { pauses[$0].seconds } ?? 0)
                if let hit { next = hit + 1 }
            }
            let cuts = list == nil ? breaks(gaps) : []
            guard !cuts.isEmpty else { return line }
            return parts.enumerated().map { i, part in cuts.contains(i) ? "\n\n" + capitalised(part) : (i == 0 ? part : " " + part) }.joined()
        }
        let out = lines.joined(separator: "\n")
        return out.last.map { $0.isLetter || $0.isNumber } == true ? out + "." : out
    }

    /// The sentence indices a paragraph starts at, given the pause before each sentence (`gaps[0]` is unused).
    static func breaks(_ gaps: [Double]) -> Set<Int> {
        var cuts = Set<Int>(), start = 0, i = 1
        let last = gaps.count - 2                             // a break leaves at least two sentences after it
        while i < gaps.count {
            if i <= last, gaps[i] >= pauseBreak {
                cuts.insert(i); start = i
            } else if i - start == forceAfter {
                let best = (start + 2...min(i, last)).reversed().max { gaps[$0] < gaps[$1] }!   // the later of equal pauses
                cuts.insert(best); start = best; i = best
            }
            i += 1
        }
        return cuts
    }

    /// Splits after `. ? !` (and closing quotes or brackets) followed by white space; the white space is dropped.
    static func sentences(_ line: String) -> [String] {
        guard let boundary = try? NSRegularExpression(pattern: "(\(terminator))\\s+") else { return [line] }
        let ns = line as NSString
        var out: [String] = [], from = 0
        for m in boundary.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: from, length: NSMaxRange(m.range(at: 1)) - from)))
            from = NSMaxRange(m.range)
        }
        return from < ns.length ? out + [ns.substring(from: from)] : out
    }

    /// The first word's letters and digits, lower case: how a pause finds its sentence again.
    static func key(_ word: String) -> String {
        String(word.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } } ?? "")
    }

    /// Cleanup has capitalised every sentence already; this only catches a plain lower-case word. "iPhone", "bbc.co.uk"
    /// (vocabulary and addresses Cleanup protected) are left as they are.
    static func capitalised(_ sentence: String) -> String {
        guard let first = sentence.first, first.isLowercase else { return sentence }
        let word = (sentence.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "").trimmingCharacters(in: .punctuationCharacters)
        return word.allSatisfy({ $0.isLowercase || "'’-".contains($0) }) ? first.uppercased() + sentence.dropFirst() : sentence
    }
}
