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
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]

    /// Words with sentence numbers. Whitespace and lone punctuation are not tokens.
    public static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var tokens: [Token] = []
        tokens.reserveCapacity(matches.count)
        var sentence = 0
        var prevEnd: Int?
        var prevStartsLine = false
        for match in matches {
            let location = match.range.location
            if let prevEnd, location > prevEnd {
                var gap = ns.substring(with: NSRange(location: prevEnd, length: location - prevEnd))
                // "1. Item": the dot after a list number that opens its line is a marker, not a sentence end.
                if prevStartsLine, gap.hasPrefix("."), let last = tokens.last, last.text.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    gap.removeFirst()
                }
                if gap.contains(where: sentenceEnders.contains) { sentence += 1 }
            }
            let range = location ..< (location + match.range.length)
            tokens.append(Token(text: ns.substring(with: match.range), range: range, sentence: sentence))
            prevEnd = range.upperBound
            prevStartsLine = startsLine(ns, at: location)
        }
        return tokens
    }

    private static func startsLine(_ ns: NSString, at location: Int) -> Bool {
        var p = location - 1
        while p >= 0, ns.character(at: p) == 0x20 || ns.character(at: p) == 0x09 { p -= 1 }
        return p < 0 || ns.character(at: p) == 0x0A
    }

    /// Whole sentences per chunk; first chunk short; never splits a token.
    ///
    /// Chunk ranges are contiguous: each runs from its first token's start to the next chunk's first token's start (so the
    /// whitespace between chunks belongs to the earlier chunk); the last ends at the text's end minus trailing whitespace. The first chunk is
    /// only the first sentence (fast first audio), cut to `firstMax` if longer; after that a chunk holds whole sentences
    /// while its range fits `max`. A sentence that does not fit is cut at the last clause boundary (`, ; : — –` then a
    /// space) that fits, else at the last whitespace, else at any token boundary; the rest of it starts the next chunk.
    public static func chunks(_ text: String, tokens: [Token], firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        chunks(text, tokens: tokens, from: 0, firstMax: firstMax, max: max)
    }

    /// Same, but the first chunk begins exactly at `tokens[startToken]` (resume / seek, mid-sentence allowed).
    public static func chunks(_ text: String, tokens: [Token], from startToken: Int, firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        guard tokens.indices.contains(startToken) else { return [] }
        let ns = text as NSString
        let count = tokens.count
        /// UTF-16 length of the chunk made of tokens[a..<b], including the whitespace that follows it.
        func length(_ a: Int, _ b: Int) -> Int {
            (b < count ? tokens[b].range.lowerBound : tokens[b - 1].range.upperBound) - tokens[a].range.lowerBound
        }
        /// Where to cut tokens[a..<b], which is too long: the first token of the next chunk, or nil when it is one token.
        func cut(_ a: Int, _ b: Int, _ limit: Int) -> Int? {
            guard a + 1 < b else { return nil }
            var clause: Int?, space: Int?, any: Int?
            for i in (a + 1)..<b {
                let len = length(a, i)
                if len > limit { break }
                any = i
                let gap = ns.substring(with: NSRange(location: tokens[i - 1].range.upperBound,
                                                     length: tokens[i].range.lowerBound - tokens[i - 1].range.upperBound))
                if gap.contains(where: \.isWhitespace) { space = i }
                // A clause cut that leaves a sliver ("Well, " + 280 characters) is worse than a whitespace cut.
                if len >= limit / 3, zip(gap, gap.dropFirst()).contains(where: { clauseMarks.contains($0) && $1.isWhitespace }) { clause = i }
            }
            return clause ?? space ?? any ?? a + 1
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
            let hi = k + 1 < starts.count ? tokens[e].range.lowerBound : textEnd
            return Chunk(range: tokens[s].range.lowerBound ..< hi, tokens: s ..< e)
        }
    }
}
