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
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

    /// Words with sentence numbers. Whitespace and lone punctuation are not tokens.
    public static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var tokens: [Token] = []
        tokens.reserveCapacity(matches.count)
        var sentence = 0
        var prevEnd: Int?
        for match in matches {
            if let prevEnd, match.range.location > prevEnd {
                let gap = ns.substring(with: NSRange(location: prevEnd, length: match.range.location - prevEnd))
                if gap.contains(where: sentenceEnders.contains) { sentence += 1 }
            }
            let range = match.range.location ..< (match.range.location + match.range.length)
            tokens.append(Token(text: ns.substring(with: match.range), range: range, sentence: sentence))
            prevEnd = range.upperBound
        }
        return tokens
    }

    /// Whole sentences per chunk; first chunk short; never splits a token. WP1.
    public static func chunks(_ text: String, tokens: [Token], firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        fatalError("WP1")
    }

    /// Same, starting at `startToken` (resume / seek). WP1.
    public static func chunks(_ text: String, tokens: [Token], from startToken: Int, firstMax: Int = 120, max: Int = 300) -> [Chunk] {
        fatalError("WP1")
    }
}
