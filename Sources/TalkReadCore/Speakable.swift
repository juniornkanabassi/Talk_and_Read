// Source text -> what the TTS engine hears, with an index map back to the source. Owned by WP1.
import Foundation

public struct Speakable: Sendable {
    /// What the engine hears.
    public let text: String
    /// Per UTF-16 unit of `text`, the source range it came from (inserted units map to the characters they stand for).
    private let lows: [Int]
    private let highs: [Int]
    /// Merged source ranges that produced at least one unit, before whitespace collapsing: what was NOT removed.
    private let covered: [Range<Int>]

    /// Identity mapping: the speakable text is its own source.
    public init(text: String) {
        let n = text.utf16.count
        self.init(text: text, lows: Array(0..<n), highs: (0..<n).map { $0 + 1 }, covered: n > 0 ? [0..<n] : [])
    }

    fileprivate init(text: String, lows: [Int], highs: [Int], covered: [Range<Int>]) {
        self.text = text; self.lows = lows; self.highs = highs; self.covered = covered
    }

    /// What the engine should say for `source[range]`. All offsets are UTF-16, in `source`'s coordinates.
    ///
    /// Lexicon (whole word, case-insensitive, longest key first); URLs and emails spoken as host words ("example dot com",
    /// the path is dropped); markdown noise dropped; `&` `%` `°C` `~5` spoken; emoji dropped; whitespace collapsed to one
    /// space; a newline becomes ". " when the line ends without punctuation, so list items get a pause.
    public static func make(_ source: String, range: Range<Int>, lexicon: [String: String]) -> Speakable {
        let ns = source as NSString
        let lo = min(max(range.lowerBound, 0), ns.length)
        let hi = min(max(range.upperBound, lo), ns.length)
        // ponytail: scanned as a slice so regex cost is per chunk, not per document; callers pass chunk-sized ranges.
        let slice = ns.substring(with: NSRange(location: lo, length: hi - lo))
        var maker = Maker(slice, lexicon: lexicon)
        maker.scan(0, maker.u.count, lineStart: true)
        return maker.finish(base: lo)
    }

    /// Speakable UTF-16 range -> source UTF-16 range: the union of the source characters those units came from.
    public func sourceRange(_ r: Range<Int>) -> Range<Int> {
        guard !lows.isEmpty else { return 0..<0 }
        if r.isEmpty {
            let p = lows[min(max(r.lowerBound, 0), lows.count - 1)]
            return p..<p
        }
        let a = max(r.lowerBound, 0), b = min(r.upperBound, lows.count)
        guard a < b else { let p = highs[lows.count - 1]; return p..<p }
        var s = Int.max, e = Int.min
        for i in a..<b { s = min(s, lows[i]); e = max(e, highs[i]) }
        return s..<e
    }

    /// Whether any speakable text came from `r` (false for URL paths, markdown noise, emoji: the removed source).
    public func covers(_ r: Range<Int>) -> Bool {
        var l = 0, h = covered.count   // first segment ending after r starts
        while l < h { let m = (l + h) / 2; if covered[m].upperBound > r.lowerBound { h = m } else { l = m + 1 } }
        return l < covered.count && covered[l].lowerBound < r.upperBound
    }
}

private enum Rx {
    static func make(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    static let marker = make("(?:#{1,6}[ \\t]+|(?:>[ \\t]*)+|[-*+•][ \\t]+)")
    static let image = make("!\\[[^\\]]*\\]\\([^)]*\\)")
    static let link = make("\\[([^\\]]*)\\]\\([^)\\s]*(?:\\s+\"[^\"]*\")?\\)")
    static let email = make("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+")
    static let url = make("https?://[^\\s<>\"]+", .caseInsensitive)
    static let www = make("www\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+(?:[/?#][^\\s<>\"]*)?", .caseInsensitive)
}

private struct Maker {
    let slice: String
    let u: [UInt16]
    let lexicon: [(NSRegularExpression, String)]
    var units: [UInt16] = [], lows: [Int] = [], highs: [Int] = []

    init(_ slice: String, lexicon: [String: String]) {
        self.slice = slice
        u = Array(slice.utf16)
        // Longest key first, so "New York City" beats "New York". Spaces in a key match any whitespace run.
        self.lexicon = lexicon.keys.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.utf16.count, $0) > ($1.utf16.count, $1) }
            .map { key in
                let body = key.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
                return (Rx.make("(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])", .caseInsensitive), lexicon[key]!)
            }
    }

    // MARK: output

    mutating func put(_ text: String, _ r: Range<Int>) {
        for unit in text.utf16 { units.append(unit); lows.append(r.lowerBound); highs.append(r.upperBound) }
    }

    mutating func copy(_ a: Int, _ b: Int) {
        for i in a..<b { units.append(u[i]); lows.append(i); highs.append(i + 1) }
    }

    // MARK: scanning

    func match(_ re: NSRegularExpression, _ p: Int, _ to: Int) -> NSTextCheckingResult? {
        re.firstMatch(in: slice, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                      range: NSRange(location: p, length: to - p))
    }

    static func isWord(_ unit: UInt16) -> Bool {
        Unicode.Scalar(UInt32(unit)).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isPictograph(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v == 0xFE0F || v == 0x200D || v == 0x20E3 || (0xE0020...0xE007F).contains(v) || (0x1F3FB...0x1F3FF).contains(v) { return true }
        return v >= 0x2190 && (s.properties.isEmojiPresentation || s.properties.isEmoji)
    }

    /// Spoken labels of a host or address: "." -> " dot ", "@" -> " at ".
    mutating func emitLabels(_ a: Int, _ b: Int) {
        var label = a
        for q in a..<b where u[q] == 0x2E || u[q] == 0x40 {
            copy(label, q)
            put(u[q] == 0x2E ? " dot " : " at ", q..<q + 1)
            label = q + 1
        }
        copy(label, b)
    }

    /// A URL or bare www address matched at p: speaks the host only (userinfo, port and path are dropped).
    /// Returns how much source it used: trailing punctuation after the address stays for the normal scan.
    mutating func emitAddress(_ p: Int, _ n: Int) -> Int {
        var end = p + n
        while end > p, ".,;:!?)]}'\"".utf16.contains(u[end - 1]) { end -= 1 }
        var h0 = p
        if let colon = (p..<end).first(where: { u[$0] == 0x3A }), colon + 2 < end, u[colon + 1] == 0x2F, u[colon + 2] == 0x2F { h0 = colon + 3 }
        var h1 = h0
        while h1 < end, ![0x2F, 0x3F, 0x23].contains(u[h1]) { h1 += 1 }
        if let at = (h0..<h1).last(where: { u[$0] == 0x40 }) { h0 = at + 1 }
        if let colon = (h0..<h1).first(where: { u[$0] == 0x3A }) { h1 = colon }
        emitLabels(h0, h1)
        return end - p
    }

    mutating func scan(_ from: Int, _ to: Int, lineStart start: Bool) {
        var p = from
        var lineStart = start
        loop: while p < to {
            let c = u[p]
            if c == 0x0A || c == 0x0D { copy(p, p + 1); p += 1; lineStart = true; continue }
            if lineStart {
                if c == 0x20 || c == 0x09 { copy(p, p + 1); p += 1; continue }
                if let m = match(Rx.marker, p, to) { p += m.range.length; continue }   // heading, quote, bullet: dropped
                lineStart = false
            }
            if p == from || !Maker.isWord(u[p - 1]) {
                for (re, value) in lexicon {
                    if let m = match(re, p, to) { put(value, p..<p + m.range.length); p += m.range.length; continue loop }
                }
                if let m = match(Rx.email, p, to) { emitLabels(p, p + m.range.length); p += m.range.length; continue }
                if let m = match(Rx.url, p, to) ?? match(Rx.www, p, to) { p += emitAddress(p, m.range.length); continue }
            }
            let next: UInt16 = p + 1 < to ? u[p + 1] : 0
            switch c {
            case 0x21: // ![alt](url)
                if let m = match(Rx.image, p, to) { p += m.range.length; continue }
            case 0x5B: // [text](url) -> text
                if let m = match(Rx.link, p, to) {
                    let t = m.range(at: 1)
                    scan(t.location, t.location + t.length, lineStart: false)
                    p += m.range.length
                    continue
                }
            case 0x2A where next == 0x2A, 0x5F where next == 0x5F: p += 2; continue   // ** and __
            case 0x60, 0x2022: p += 1; continue                                         // backtick, bullet
            case 0x26: put(" and ", p..<p + 1); p += 1; continue
            case 0x25 where p > 0 && Maker.isDigit(u[p - 1]): put(" percent", p..<p + 1); p += 1; continue
            case 0xB0:
                if next == 0x43 || next == 0x46, p + 2 >= to || !Maker.isWord(u[p + 2]) {
                    put(next == 0x43 ? " degrees Celsius" : " degrees Fahrenheit", p..<p + 2); p += 2
                } else { put(" degrees", p..<p + 1); p += 1 }
                continue
            case 0x7E:
                var q = p + 1
                while q < to, u[q] == 0x20 { q += 1 }
                if q < to, Maker.isDigit(u[q]) || u[q] == 0xA3 || u[q] == 0x24 || u[q] == 0x20AC { put("about ", p..<p + 1); p += 1; continue }
            default: break
            }
            var value = UInt32(c), size = 1
            if (0xD800..<0xDC00).contains(c), p + 1 < to, (0xDC00..<0xE000).contains(u[p + 1]) {
                value = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(u[p + 1]) - 0xDC00); size = 2
            }
            if let scalar = Unicode.Scalar(value), Maker.isPictograph(scalar) { p += size; continue }
            copy(p, p + size)
            p += size
        }
    }

    // MARK: finishing

    /// Collapses whitespace runs, turns unpunctuated line ends into ". ", trims, and shifts the map to source coordinates.
    func finish(base: Int) -> Speakable {
        var out: [UInt16] = [], lo: [Int] = [], hi: [Int] = []
        func endsWithPunctuation() -> Bool {
            var i = out.count - 1
            while i >= 0, "\"'”’)]}".utf16.contains(out[i]) { i -= 1 }
            return i >= 0 && ".!?:;,…".utf16.contains(out[i])
        }
        var i = 0
        while i < units.count {
            let unit = units[i]
            guard unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 else {
                out.append(unit); lo.append(lows[i] + base); hi.append(highs[i] + base); i += 1; continue
            }
            var j = i, newline = false
            var a = Int.max, b = Int.min
            while j < units.count, [0x20, 0x09, 0x0A, 0x0D, 0xA0].contains(units[j]) {
                if units[j] == 0x0A || units[j] == 0x0D { newline = true }
                a = min(a, lows[j]); b = max(b, highs[j]); j += 1
            }
            if !out.isEmpty, j < units.count {
                if newline, !endsWithPunctuation() { out.append(0x2E); lo.append(a + base); hi.append(b + base) }
                out.append(0x20); lo.append(a + base); hi.append(b + base)
            }
            i = j
        }
        var covered: [Range<Int>] = []
        for k in units.indices {
            let r = lows[k] + base ..< highs[k] + base
            if let last = covered.last, r.lowerBound <= last.upperBound { covered[covered.count - 1] = last.lowerBound ..< max(last.upperBound, r.upperBound) }
            else { covered.append(r) }
        }
        return Speakable(text: String(decoding: out, as: UTF16.self), lows: lo, highs: hi, covered: covered)
    }
}
