// Paragraphs for long dictations (F-A, PLAN 0.6.0; F12 rework). `split` runs on the recogniser's raw text, where the pauses
// line up with the sentences exactly, and puts `\n\n` before a sentence that follows a pause; Cleanup then runs on that text
// and keeps the breaks. `tidy` runs after Cleanup: it keeps lists whole and gives the last sentence its full stop. A
// dictation under `minWords` is returned exactly as it came.
import Foundation
import NaturalLanguage

public enum Paragraphs {
    // ponytail: constants from the plan, not tuned on Junior's own speech yet; adjust after live use.
    /// Shorter dictations (talking to an assistant) are left alone.
    static let minWords = 60
    /// A pause of at least this many seconds before a sentence starts a new paragraph.
    static let pauseBreak = 1.0
    /// With no such pause for this many sentences, a break is forced at the longest pause among sentences 3 to 6.
    static let forceAfter = 5

    // MARK: Timed words and pauses

    /// A recogniser's sub-word piece: its text (a leading space starts a word) and its times in seconds.
    public struct Piece: Equatable, Sendable {
        public var text: String, start: Double, end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    /// A word with its extent. `reliable` is false when its pieces' times ran backwards or contradict themselves.
    public struct Word: Equatable, Sendable {
        public var text: String, start: Double, end: Double, reliable: Bool
        public init(text: String, start: Double, end: Double, reliable: Bool = true) {
            self.text = text; self.start = start; self.end = end; self.reliable = reliable
        }
    }

    /// Groups pieces into words. A punctuation piece joins its word but never moves its end (the model emits a full stop
    /// late, next to the following word, which would hide the pause). A word's extent only grows: a continuation piece that
    /// starts before the word or ends before it marks the word unreliable instead of moving its end back.
    public static func words(from pieces: [Piece]) -> [Word] {
        var words: [Word] = []
        for p in pieces where !p.text.isEmpty {
            let text = p.text.trimmingCharacters(in: .whitespaces)
            let mark = !text.isEmpty && text.allSatisfy(\.isPunctuation)
            if let last = words.indices.last, mark || !p.text.hasPrefix(" ") {
                words[last].text += text
                guard !mark else { continue }
                if p.start < words[last].start || p.end < words[last].end || p.end < p.start { words[last].reliable = false }
                else { words[last].end = p.end }
            } else {
                words.append(Word(text: text, start: p.start, end: p.end, reliable: p.end >= p.start))
            }
        }
        return words
    }

    /// The silence before each sentence of `text`, one entry per sentence (the first has none). nil when it is not known:
    /// a word could not be placed in the text, a word's times are unreliable, or the two words are out of order. Unknown is
    /// never evidence for a break.
    public static func pauses(text: String, words: [Word]) -> [Double?] {
        var at: [String.Index: Int] = [:], cursor = text.startIndex, placed = [Bool](repeating: false, count: words.count)
        for (k, w) in words.enumerated() {
            if !w.text.isEmpty, let r = text.range(of: w.text, range: cursor..<text.endIndex) {
                at[r.lowerBound] = k; placed[k] = true; cursor = r.upperBound
            }
        }
        return sentenceRanges(text).enumerated().map { i, span in
            // The sentence's first word starts at its first character, or just after an opening quote or bracket.
            let lexical = text[span].firstIndex { $0.isLetter || $0.isNumber } ?? span.lowerBound
            guard i > 0, let k = at.first(where: { $0.key >= span.lowerBound && $0.key <= lexical })?.value, k > 0, placed[k - 1],
                  words[k].reliable, words[k - 1].reliable, words[k].start >= words[k - 1].start else { return nil }
            return max(0, words[k].start - words[k - 1].end)
        }
    }

    // MARK: Split (before Cleanup)

    /// `text` with `\n\n` before sentences that follow a pause of a second or more, and a forced break in a run of sentences
    /// with none. `pauses` has one entry per sentence of `text` (anything else is ignored: no pauses known). Never inside a
    /// sentence, never next to a spoken "new paragraph" or "new line" or a line break already there, never leaving a
    /// one-sentence paragraph at the end of a stretch. Only white space between sentences changes.
    public static func split(_ text: String, pauses: [Double?] = []) -> String {
        guard text.split(whereSeparator: \.isWhitespace).count >= minWords else { return text }
        let spans = sentenceRanges(text)
        let known = pauses.count == spans.count
        // A spoken list ("First, … Second, …") becomes numbered lines in Cleanup: no automatic break inside it. The last item may
        // run on, up to the next sentence that follows a clear pause.
        var listed = Set<Int>()
        let markers = Cleanup.listRun(text).compactMap { m -> Int? in
            let at = String.Index(utf16Offset: m.0.range(at: 2).location, in: text)
            return spans.lastIndex { $0.lowerBound <= at }
        }
        if let firstItem = markers.first, let lastItem = markers.last {
            listed.formUnion(firstItem...lastItem)
            var k = lastItem + 1
            while k < spans.count, (known ? (pauses[k] ?? 0) : 0) < pauseBreak { listed.insert(k); k += 1 }
        }
        var cuts: [Int] = [], first = 0
        while first < spans.count {
            var end = first + 1                                       // a stretch: sentences with no line break between them
            while end < spans.count, !text[spans[end - 1].upperBound..<spans[end].lowerBound].contains("\n") { end += 1 }
            let spoken = (first..<end).filter { text[spans[$0]].range(of: "\\bnew (?:paragraph|line)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
            // A line that is a list item (`1.`, `1)`, `-`, `•`, `*`) stays whole, however many sentences it runs on.
            let lineStart = text[..<spans[first].lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let isItem = text[lineStart..<spans[end - 1].upperBound].range(of: item, options: .regularExpression) != nil
            let blocked = isItem ? Set(0..<(end - first))
                : Set(spoken.flatMap { [$0 - 1 - first, $0 - first, $0 + 1 - first] } + listed.map { $0 - first })
            cuts += breaks((first..<end).map { known ? (pauses[$0] ?? 0) : 0 }, blocked: blocked).map { $0 + first }
            first = end
        }
        var out = "", from = text.startIndex
        for i in cuts.sorted() {
            out += text[from..<spans[i - 1].upperBound] + "\n\n"
            from = spans[i].lowerBound
        }
        return out + text[from...]
    }

    /// The sentence indices a paragraph starts at, given the pause before each sentence (`gaps[0]` is unused).
    static func breaks(_ gaps: [Double], blocked: Set<Int> = []) -> Set<Int> {
        var cuts = Set<Int>(), start = 0, i = 1
        let last = gaps.count - 2                                     // a break leaves at least two sentences after it
        func allowed(_ k: Int) -> Bool { k <= last && !blocked.contains(k) }
        while i < gaps.count {
            if allowed(i), gaps[i] >= pauseBreak {
                cuts.insert(i); start = i
            } else if i - start >= forceAfter,
                      let best = (start + 2...min(i, last)).reversed().filter(allowed).max(by: { gaps[$0] < gaps[$1] }) {   // the later of equal pauses
                cuts.insert(best); start = best; i = best
            }
            i += 1
        }
        return cuts
    }

    /// The sentences of `text` as trimmed ranges. NaturalLanguage knows "Dr.", "No. 5", "p.m." and ellipses; a piece that
    /// starts with a closing quote or bracket (French « oui ! » Ensuite) belongs to the sentence before it.
    static func sentenceRanges(_ text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi, text[lo].isWhitespace { lo = text.index(after: lo) }
            while hi > lo, text[text.index(before: hi)].isWhitespace { hi = text.index(before: hi) }
            guard lo < hi else { return true }
            // A leading closing quote or bracket (French « oui ! » Ensuite) belongs to the sentence before; the rest stays a sentence.
            var closers = lo
            while let previous = out.last, closers < hi, "»”’)]".contains(text[closers]) {
                closers = text.index(after: closers)
                out[out.count - 1] = previous.lowerBound..<closers
                lo = closers
                while lo < hi, text[lo].isWhitespace { lo = text.index(after: lo) }
                closers = lo
            }
            if lo < hi { out.append(lo..<hi) }
            return true
        }
        return out
    }

    // MARK: Tidy (after Cleanup)

    private static let item = "^\\s*(?:\\d{1,3}[.)]|[-•*])\\s+\\S"

    /// For 60 words or more: no blank line between list items (lines starting `1.`, `1)`, `-`, `•` or `*`, indented or not),
    /// and a full stop after the last word when it has no sentence end, outside any closing quote, bracket or space
    /// ("yes". (probably tomorrow). « oui »).
    public static func tidy(_ text: String) -> String {
        guard text.split(whereSeparator: \.isWhitespace).count >= minWords else { return text }
        let lines = text.components(separatedBy: "\n")
        let isItem = { (line: String) in line.range(of: item, options: .regularExpression) != nil }
        let isBlank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }
        // Blank lines between two list items go. Prose between lists is never pulled into an item, and an item that runs
        // on after a blank line (or a one-item list) is left as it is.
        var kept: [String] = [], i = 0
        while i < lines.count {
            guard isBlank(lines[i]) else { kept.append(lines[i]); i += 1; continue }
            var j = i
            while j < lines.count, isBlank(lines[j]) { j += 1 }
            if !((kept.last.map(isItem) ?? false) && j < lines.count && isItem(lines[j])) { kept += lines[i..<j] }
            i = j
        }
        var out = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let word = out.last(where: { !"\"'”’)]»".contains($0) && !$0.isWhitespace }), word.isLetter || word.isNumber { out += "." }
        return out
    }
}
