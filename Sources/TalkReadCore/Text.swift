// Tokenizer (word ranges, sentence index) and the TTS chunker. Tokenizer is ReadAlong 1.0.5's; chunker is WP1.
import Foundation

public struct Token: Equatable, Sendable {
    public let text: String
    /// UTF-16 offsets into the captured text.
    public let range: Range<Int>
    public let sentence: Int
    public init(text: String, range: Range<Int>, sentence: Int) { self.text = text; self.range = range; self.sentence = sentence }
}

public struct Chunk: Equatable, Sendable {
    public let range: Range<Int>
    /// Indices into the `[Token]` the chunk was built from.
    public let tokens: Range<Int>
    public init(range: Range<Int>, tokens: Range<Int>) { self.range = range; self.tokens = tokens }
}

public enum TextKit {
    // ponytail: one NSRegularExpression instance, built once; ICU regex already gives UTF-16 NSRange for free.
    private static let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*")
    // A gap holding one of these starts a new sentence. A line starting "- ", "* " or "12." is always preceded by a
    // newline (or the text start), so the newline already covers list items; "•" is the one marker that can sit mid-line.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n", "•"]
    // ponytail: small fixed English list; a title never ends a sentence, the others only before a lowercase word or digit.
    private static let titles: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st"]
    private static let abbreviations: Set<String> = ["vs", "etc", "no", "approx", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    private static let dottedAbbreviations: Set<String> = ["eg", "ie", "am", "pm"]   // e.g. i.e. a.m. p.m., as their two letter tokens
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]
    // ponytail: one pass over the text per chunks() call; a read recuts from a token, so a huge document pays it per recut.
    private static let protectedSpans = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|`[^`\\n]+`")

    /// Words with sentence numbers. Whitespace and lone punctuation are not tokens.
    public static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var tokens: [Token] = []
        tokens.reserveCapacity(matches.count)
        var sentence = 0
        var prevEnd: Int?
        var prevStartsLine = false
        var initials = ""   // the previous two tokens when they are dotted single letters ("e.g.", "a.m."), else ""
        for match in matches {
            let location = match.range.location
            if let prevEnd, location > prevEnd {
                var gap = ns.substring(with: NSRange(location: prevEnd, length: location - prevEnd))
                // "1. Item": the dot after a list number that opens its line is a marker, not a sentence end.
                if prevStartsLine, gap.hasPrefix("."), let last = tokens.last, last.text.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    gap.removeFirst()
                }
                if gap.contains(where: sentenceEnders.contains), !(tokens.last.map { joins(gap, $0.text, initials, ns.substring(with: match.range)) } ?? false) { sentence += 1 }
            }
            let range = location ..< (location + match.range.length)
            let word = ns.substring(with: match.range)
            initials = prevEnd == location - 1 && ns.character(at: location - 1) == 0x2E && tokens.last?.text.count == 1 && word.count == 1
                ? (tokens.last!.text + word).lowercased() : ""
            tokens.append(Token(text: word, range: range, sentence: sentence))
            prevEnd = range.upperBound
            prevStartsLine = startsLine(ns, at: location)
        }
        return tokens
    }

    /// True when a gap that contains a sentence mark is not a sentence end: "3.5", "U.S.", "Mr. Patel", "9 a.m. on",
    /// "guide.md". A full stop glued to a capital ("here.Next", as Chromium joins paragraphs) still ends one.
    private static func joins(_ gap: String, _ prev: String, _ initials: String, _ next: String) -> Bool {
        guard gap.first == "." else { return false }
        if gap.count == 1 {   // no space: decimals, dates, dotted initials, and file names and addresses ("plan.md", "bbc.co.uk")
            return prev.allSatisfy(\.isNumber) && next.allSatisfy(\.isNumber) || prev.count == 1 && prev.first!.isLetter && next.first!.isLetter
                || next.first!.isLowercase
        }
        guard gap.dropFirst().allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
        let word = prev.lowercased()
        if titles.contains(word) { return true }
        return (next.first!.isLowercase || next.first!.isNumber) && (abbreviations.contains(word) || dottedAbbreviations.contains(initials))
    }

    private static func startsLine(_ ns: NSString, at location: Int) -> Bool {
        var p = location - 1
        while p >= 0, ns.character(at: p) == 0x20 || ns.character(at: p) == 0x09 { p -= 1 }
        return p < 0 || ns.character(at: p) == 0x0A
    }

    /// Whole sentences per chunk; first chunk short; never splits a token.
    ///
    /// Chunk ranges are contiguous: each begins where the previous one ends, at the start of the non-whitespace run holding
    /// its first token (so a prefix such as "£45", "\"Hello" or "(see" is spoken with its token; never a sentence/clause
    /// mark or a joiner glued to the previous token), and the whitespace between chunks belongs to the earlier chunk; the last ends
    /// at the text's end minus trailing whitespace. The first chunk is
    /// only the first sentence (fast first audio), cut to `firstMax` if longer; after that a chunk holds whole sentences
    /// while its range fits `max`. A sentence that does not fit is cut at the last clause boundary (`, ; : — –` then a
    /// space) that fits, else at the last whitespace, else at any token boundary; the rest of it starts the next chunk.
    public static func chunks(_ text: String, tokens: [Token], firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        chunks(text, tokens: tokens, from: 0, firstMax: firstMax, max: max)
    }

    /// Same, but the first chunk begins at `tokens[startToken]` (resume / seek, mid-sentence allowed), with its prefix.
    public static func chunks(_ text: String, tokens: [Token], from startToken: Int, firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        guard tokens.indices.contains(startToken) else { return [] }
        let ns = text as NSString
        let count = tokens.count
        /// Where a chunk opening with tokens[i] begins: back over the token's prefix to whitespace or a sentence or clause
        /// mark. A token glued to the previous one ("well-known", "and/or") has a joiner, not a prefix: it starts bare.
        func lead(_ i: Int) -> Int {
            let floor = i > 0 ? tokens[i - 1].range.upperBound : 0
            var p = tokens[i].range.lowerBound
            while p > floor, let scalar = Unicode.Scalar(ns.character(at: p - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !sentenceEnders.contains(Character(scalar)), !clauseMarks.contains(Character(scalar)) { p -= 1 }
            return p == floor && i > 0 ? tokens[i].range.lowerBound : p
        }
        /// UTF-16 length of the chunk made of tokens[a..<b], including the whitespace that follows it.
        func length(_ a: Int, _ b: Int) -> Int {
            (b < count ? lead(b) : tokens[b - 1].range.upperBound) - lead(a)
        }
        /// Markdown links and code spans, never cut: a chunk speaks a link's label or a path's file name only when it
        /// holds the whole construct (Speakable).
        let kept = protectedSpans.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location..<$0.range.location + $0.range.length }
        func insideKept(_ p: Int) -> Bool {
            var l = 0, h = kept.count   // first span ending after p
            while l < h { let m = (l + h) / 2; if kept[m].upperBound > p { h = m } else { l = m + 1 } }
            return l < kept.count && kept[l].lowerBound < p
        }
        /// Where to cut tokens[a..<b], which is too long: the first token of the next chunk, or nil when it is one token.
        /// Never inside a link or code span; when the limit falls inside one, the chunk runs on past it.
        func cut(_ a: Int, _ b: Int, _ limit: Int) -> Int? {
            guard a + 1 < b else { return nil }
            var clause: Int?, space: Int?, any: Int?
            for i in (a + 1)..<b {
                let len = length(a, i)
                if len > limit { break }
                if insideKept(tokens[i].range.lowerBound) { continue }
                any = i
                let gap = ns.substring(with: NSRange(location: tokens[i - 1].range.upperBound,
                                                     length: tokens[i].range.lowerBound - tokens[i - 1].range.upperBound))
                if gap.contains(where: \.isWhitespace) { space = i }
                // A clause cut that leaves a sliver ("Well, " + 280 characters) is worse than a whitespace cut.
                if len >= limit / 3, zip(gap, gap.dropFirst()).contains(where: { clauseMarks.contains($0) && $1.isWhitespace }) { clause = i }
            }
            return clause ?? space ?? any ?? ((a + 1)..<b).first { !insideKept(tokens[$0].range.lowerBound) } ?? a + 1
        }

        var starts = [startToken]   // first token of every chunk
        var limit = firstMax
        var a = startToken
        while a < count {
            var b = a + 1
            while b < count, tokens[b].sentence == tokens[a].sentence { b += 1 }
            var cs = starts[starts.count - 1]
            if cs < a, starts.count == 1 || length(cs, b) > limit { starts.append(a); cs = a; limit = max }   // chunk 0 is one sentence
            while length(cs, b) > limit, let i = cut(cs, b, limit) { starts.append(i); cs = i; limit = max }
            a = b
        }
        // The last chunk keeps the text's closing punctuation (a final "?" changes the voice's intonation), not trailing whitespace.
        var textEnd = ns.length
        while textEnd > tokens[count - 1].range.upperBound,
              let scalar = Unicode.Scalar(ns.character(at: textEnd - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { textEnd -= 1 }
        return starts.indices.map { k in
            let s = starts[k], e = k + 1 < starts.count ? starts[k + 1] : count
            return Chunk(range: lead(s) ..< (k + 1 < starts.count ? lead(e) : textEnd), tokens: s ..< e)
        }
    }
}
