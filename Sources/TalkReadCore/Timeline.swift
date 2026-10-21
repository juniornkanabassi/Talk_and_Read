// Engine word timings and the media-time timeline the highlight reads. Owned by WP1.
import Foundation

/// Engine output, chunk-local seconds.
public struct SpokenWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    /// UTF-16 range in the speakable text when the engine knows it (system voice markers), else nil.
    public let range: Range<Int>?
    public init(text: String, start: Double, end: Double, range: Range<Int>? = nil) {
        self.text = text; self.start = start; self.end = end; self.range = range
    }
}

/// Media time (renderer timeline at 1x, before rate). `token` indexes the whole read's `[Token]`.
public struct WordTiming: Equatable, Sendable {
    public let token: Int
    public let start: Double
    public let end: Double
    public init(token: Int, start: Double, end: Double) { self.token = token; self.start = start; self.end = end }
}

public enum Timeline {
    /// Token timings for one chunk: each source token gets [min start, max end] of its spoken words + offset;
    /// tokens with no spoken word get a zero-length timing at the next timed token's start (or chunk end).
    public static func timings(chunkTokens: [Token], chunkTokenOffset: Int, speakable: Speakable, spoken: [SpokenWord], offset: Double, chunkDuration: Double) -> [WordTiming] {
        fatalError("WP1")
    }

    /// Binary search; returns an index into `timings`.
    public static func index(at time: Double, in timings: [WordTiming]) -> Int? {
        fatalError("WP1")
    }
}
