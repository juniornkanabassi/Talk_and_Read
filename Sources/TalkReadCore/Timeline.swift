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
    /// Token timings for one chunk, one per chunk token, in token order, inside `[offset, offset + chunkDuration]`.
    ///
    /// Path: spoken word -> speakable word (its `range`, else `Alignment.assign` against the speakable text's tokens) ->
    /// `Speakable.sourceRange` -> every overlapping source token. A token gets [min start, max end] of its spoken words.
    /// Tokens that map to exactly the same spoken words ("New York" said "nyc") split that interval by length.
    /// Tokens with no spoken word share the gap to their timed neighbours by length; tokens Speakable removed (URL parts,
    /// markdown, emoji), and unmatched tokens with no gap to share, get zero-length sentinels (start == end) that are never
    /// highlighted: `index(at:in:)` skips them, so the previous word stays lit.
    public static func timings(chunkTokens: [Token], chunkTokenOffset: Int, speakable: Speakable, spoken: [SpokenWord], offset: Double, chunkDuration: Double) -> [WordTiming] {
        let n = chunkTokens.count
        guard n > 0 else { return [] }
        let duration = max(0, chunkDuration.isFinite ? chunkDuration : 0)
        func clamp(_ t: Double) -> Double { min(max(t.isFinite ? t : 0, 0), duration) }
        let epsilon = 1e-9

        // 1. Which spoken words does each source token carry?
        let words = TextKit.tokenize(speakable.text)
        let assigned = spoken.contains { $0.range == nil } ? Alignment.assign(spoken: spoken.map(\.text), source: words.map(\.text)) : []
        var owners = [[Int]](repeating: [], count: n)
        for (j, word) in spoken.enumerated() {
            let range: Range<Int>
            if let given = word.range { range = given } else if j < assigned.count, let k = assigned[j] { range = words[k].range } else { continue }
            let source = speakable.sourceRange(range)
            var lo = 0, hi = n   // first token ending after the source range starts
            while lo < hi { let mid = (lo + hi) / 2; if chunkTokens[mid].range.upperBound > source.lowerBound { hi = mid } else { lo = mid + 1 } }
            var i = lo
            while i < n, chunkTokens[i].range.lowerBound < source.upperBound || (source.isEmpty && chunkTokens[i].range.lowerBound <= source.lowerBound) {
                owners[i].append(j); i += 1
            }
        }

        // 2. Interval of each token's spoken words, chunk-local.
        var start = [Double](repeating: 0, count: n), end = start
        for i in 0..<n where !owners[i].isEmpty {
            start[i] = owners[i].map { clamp(spoken[$0].start) }.min()!
            end[i] = owners[i].map { max(clamp(spoken[$0].start), clamp(spoken[$0].end)) }.max()!
        }

        // 3. Tokens with the very same spoken words split their shared interval by character length.
        var groups: [[Int]: [Int]] = [:]
        for i in 0..<n where !owners[i].isEmpty { groups[owners[i], default: []].append(i) }
        for members in groups.values where members.count > 1 {
            let a = start[members[0]], b = end[members[0]]
            let total = members.reduce(0) { $0 + chunkTokens[$1].range.count }
            var used = 0
            for i in members {
                start[i] = a + (b - a) * Double(used) / Double(total)
                used += chunkTokens[i].range.count
                end[i] = used == total ? b : a + (b - a) * Double(used) / Double(total)
            }
        }

        // 4. Timed tokens must not overlap or go backwards; one squeezed to nothing counts as untimed.
        var timed = owners.map { !$0.isEmpty }
        var cursor = 0.0
        for i in 0..<n where timed[i] {
            start[i] = max(start[i], cursor)
            if end[i] - start[i] > epsilon { cursor = end[i] } else { timed[i] = false }
        }

        // 5. Untimed tokens share the gap between their timed neighbours; removed ones and zero gaps get sentinels.
        var out: [WordTiming] = []
        out.reserveCapacity(n)
        func emit(_ i: Int, _ s: Double, _ e: Double) {
            out.append(WordTiming(token: chunkTokenOffset + i, start: offset + s, end: offset + e))
        }
        cursor = 0
        var i = 0
        while i < n {
            if timed[i] { emit(i, start[i], end[i]); cursor = end[i]; i += 1; continue }
            var j = i
            while j < n, !timed[j] { j += 1 }
            let next = j < n ? start[j] : duration
            let gap = max(0, next - cursor)
            let sharing = (i..<j).filter { speakable.covers(chunkTokens[$0].range) }
            let total = sharing.reduce(0) { $0 + chunkTokens[$1].range.count }
            var at = cursor, used = 0
            for q in i..<j {
                guard gap > epsilon, sharing.contains(q) else { emit(q, at, at); continue }
                used += chunkTokens[q].range.count
                let t = used == total ? next : cursor + gap * Double(used) / Double(total)
                emit(q, at, t)
                at = t
            }
            i = j
        }
        return out
    }

    /// Index of the timing being spoken at `time`: the last one that started, skipping zero-length sentinels (the previous
    /// word stays lit). nil before the first word; after the last word's end it stays on the last word.
    public static func index(at time: Double, in timings: [WordTiming]) -> Int? {
        var lo = 0, hi = timings.count
        while lo < hi { let mid = (lo + hi) / 2; if timings[mid].start <= time { lo = mid + 1 } else { hi = mid } }
        var i = lo - 1
        while i >= 0, timings[i].end <= timings[i].start { i -= 1 }
        return i >= 0 ? i : nil
    }
}
