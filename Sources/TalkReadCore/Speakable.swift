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
    /// `language`: "en" or "fr". French text also gets French spoken forms: numbers ("4,2 millions", years), dates
    /// ("14 novembre", "1er", "14/11/2027"), times ("11h20"), `%` ("pour cent"), `°C` ("degrés Celsius"), `€ $ £`, `&` ("et"),
    /// "point" and "arobase" in addresses. English is unchanged (the engine's own normaliser reads English digits).
    /// `skip`: source ranges never spoken (a PDF's running headers, footers and page numbers).
    /// `skipCitations`: reference marks are dropped: "[12]", "[3, 5–7]", "[citation needed]" glued to the word or
    /// punctuation before them (a spaced "at [45]" or a line's "[23]" is a paragraph reference and is read), superscript
    /// digits after punctuation or a long word, and 1 to 3 plain digits glued to the full stop after a word of four
    /// letters or more and followed by a capital ("consideration.12 The"), which is how a PDF's footnote marks come out;
    /// "s.12", "para.4", "Goals:12", "3.5" and "1,000" are kept.
    public static func make(_ source: String, range: Range<Int>, lexicon: [String: String], language: String = "en",
                            skip: [Range<Int>] = [], skipCitations: Bool = false) -> Speakable {
        let ns = source as NSString
        let lo = min(max(range.lowerBound, 0), ns.length)
        let hi = min(max(range.upperBound, lo), ns.length)
        // ponytail: scanned as a slice so regex cost is per chunk, not per document; callers pass chunk-sized ranges.
        // The slice starts up to 80 characters early, back to its line's start, so a mark at the chunk's start is judged
        // in context (a footnote "12" the chunker split from "consideration.", a "[12]" glued to the previous chunk's
        // last word). That context is read, never spoken.
        var ctx = lo
        while ctx > 0, lo - ctx < 80, ns.character(at: ctx - 1) != 0x0A, ns.character(at: ctx - 1) != 0x0D { ctx -= 1 }
        let slice = ns.substring(with: NSRange(location: ctx, length: hi - ctx))
        var maker = Maker(slice, lexicon: lexicon, french: language == "fr")
        maker.citations = skipCitations
        for r in skip.sorted(by: { $0.lowerBound < $1.lowerBound }) {   // into slice coordinates, overlaps merged
            let a = max(r.lowerBound, lo) - ctx, b = min(r.upperBound, hi) - ctx
            guard a < b else { continue }
            if let last = maker.skip.last, a <= last.upperBound { maker.skip[maker.skip.count - 1] = last.lowerBound..<max(b, last.upperBound) }
            else { maker.skip.append(a..<b) }
        }
        maker.scanAll(from: lo - ctx, sliceStartsLine: ctx == 0 || [0x0A, 0x0D].contains(ns.character(at: ctx - 1)))
        return maker.finish(base: ctx)
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
    static let citation = make("\\[\\s*(?:[0-9]{1,3}[a-z]?(?:\\s*[,–—-]\\s*[0-9]{1,3}[a-z]?)*|(?:citation|clarification) needed)\\s*\\]", .caseInsensitive)
    static let www = make("www\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+(?:[/?#][^\\s<>\"]*)?", .caseInsensitive)
    // French. Digit groups: "12 345" (space, no-break or narrow no-break), "1.000.000" (two or more dot groups); "," or "." then digits is a decimal.
    // ponytail: a plain space groups too, so a list "100 200 300" reads as one number; French text writes thousands that way.
    static let frNumber = make("((?:[0-9]{1,3}(?:[\\u00A0\\u202F ][0-9]{3})+(?![0-9])|[0-9]{1,3}(?:\\.[0-9]{3}){2,}(?![0-9])|[0-9]+))(?:[,.]([0-9]+))?")
    static let frDate = make("([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})(?![0-9])")
    static let frTime = make("([0-9]{1,2})(?:h([0-9]{2})?|:([0-9]{2}))(?![\\p{L}\\p{N}])")
    static let frOrdinal = make("(er|re|ère|e|ème|eme|nd|nde)(?![\\p{L}\\p{N}])")
    static let frMonth = make("[\\u00A0 ]+(?:" + FrenchNumbers.months.joined(separator: "|") + ")(?![\\p{L}])", .caseInsensitive)
    static let frCurrency = make("[\\u00A0\\u202F ]?([€$£])")
}

private struct Maker {
    let slice: String
    let u: [UInt16]
    let french: Bool
    let lexicon: [(NSRegularExpression, String)]
    var units: [UInt16] = [], lows: [Int] = [], highs: [Int] = []
    /// Slice ranges never spoken, sorted by start.
    var skip: [Range<Int>] = []
    /// Output positions where skipped text was: a line break there joins two halves of one sentence (a page break
    /// with its footer and running head removed), so it gets no full stop.
    var skippedAt: Set<Int> = []
    var citations = false

    init(_ slice: String, lexicon: [String: String], french: Bool) {
        self.slice = slice
        self.french = french
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

    /// Spoken labels of a host or address: "." -> " dot ", "@" -> " at " (French " point ", " arobase ").
    mutating func emitLabels(_ a: Int, _ b: Int) {
        var label = a
        for q in a..<b where u[q] == 0x2E || u[q] == 0x40 {
            copy(label, q)
            put(u[q] == 0x2E ? (french ? " point " : " dot ") : (french ? " arobase " : " at "), q..<q + 1)
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

    /// True when p begins its line (only spaces or tabs before it on the line); `sliceStartsLine` says whether index 0 does.
    func startsLine(_ p: Int, sliceStartsLine: Bool) -> Bool {
        var i = p
        while i > 0, u[i - 1] == 0x20 || u[i - 1] == 0x09 { i -= 1 }
        return i == 0 ? sliceStartsLine : u[i - 1] == 0x0A || u[i - 1] == 0x0D
    }

    /// Scans the slice from `from` around the skip ranges, one stretch at a time, so no lexicon key, link or address
    /// match reaches into skipped text (a skipped word would otherwise be spoken and timed).
    mutating func scanAll(from: Int, sliceStartsLine: Bool) {
        var a = from
        for r in skip + [u.count..<u.count] where r.upperBound > a {
            if r.lowerBound > a { scan(a, r.lowerBound, lineStart: startsLine(a, sliceStartsLine: sliceStartsLine)) }
            if !r.isEmpty { skippedAt.insert(units.count) }
            a = max(a, r.upperBound)
        }
    }

    /// Abbreviations of four letters or more that a number follows ("para.4", "arts.8"): the number is read.
    static let shortForms: Set<String> = ["para", "paras", "sect", "secs", "sched", "chap", "page", "pages", "note", "notes", "fig", "figs",
                                          "vols", "arts", "regs", "rule", "rules", "ords", "apps", "ibid"]

    /// The run of letters ending at `end` (exclusive), lower-cased.
    func word(endingAt end: Int) -> String {
        var a = end
        while a > 0, let s = Unicode.Scalar(UInt32(u[a - 1])), CharacterSet.letters.contains(s) { a -= 1 }
        return String(decoding: u[a..<end], as: UTF16.self).lowercased()
    }

    /// Whether the unit before p ends a word or its punctuation, so a mark at p is glued to it ("void[12]", "void.[12]",
    /// "[1][2]"). A spaced bracket is a reference to be read ("at [45]", "[23]–[25]").
    func glued(_ p: Int) -> Bool {
        guard p > 0 else { return false }
        let before = u[p - 1]
        // "paras [12],[13]": a comma straight after a bracket continues a list of references, which is read.
        if before == 0x2C, p > 1, u[p - 2] == 0x5D { return false }
        return Maker.isWord(before) && !Maker.isDigit(before) || ".,;:)]\"'”’".utf16.contains(before)
    }

    /// How much source a footnote mark at p uses: superscript digits after punctuation or a long word, or 1 to 3 plain
    /// digits glued to the full stop or semicolon after a long word and followed by a capital or the line's end
    /// ("consideration.12 The"). nil when p starts no mark.
    func footnoteMark(_ p: Int, _ to: Int) -> Int? {
        guard p > 0 else { return nil }
        let superscripts: Set<UInt16> = [0x00B9, 0x00B2, 0x00B3, 0x2070, 0x2074, 0x2075, 0x2076, 0x2077, 0x2078, 0x2079]
        let before = u[p - 1]
        if superscripts.contains(u[p]) {
            var q = p   // "¹,²" is one mark; a comma after the last one is the sentence's ("Smith¹, Jones")
            while q < to, superscripts.contains(u[q]) || u[q] == 0x2C && q + 1 < to && superscripts.contains(u[q + 1]) { q += 1 }
            // After punctuation, or after a word of four letters or more ("m²" and "x³" are maths and stay).
            return ".,;:)]\"'”’".utf16.contains(before) || word(endingAt: p).count >= 4 ? q - p : nil
        }
        // Plain digits: not after a colon ("Goals:12") or a straight quote, which also opens a quotation.
        let closers = "”’)]".utf16, enders = ".;".utf16
        guard Maker.isDigit(u[p]), closers.contains(before) || enders.contains(before) else { return nil }
        var q = p
        while q < to, Maker.isDigit(u[q]) { q += 1 }
        guard q - p <= 3 else { return nil }
        var r = q   // what follows: the line's end, or spaces then a capital
        while r < to, u[r] == 0x20 || u[r] == 0x09 || u[r] == 0xA0 { r += 1 }
        guard r == to || u[r] == 0x0A || u[r] == 0x0D
                || r > q && Unicode.Scalar(UInt32(u[r])).map({ CharacterSet.uppercaseLetters.contains($0) }) == true else { return nil }
        var w = p - 1   // back over the punctuation to the word (a closer may follow an ender: "end.”12")
        while w > 0, closers.contains(u[w]) || enders.contains(u[w]) { w -= 1 }
        let name = word(endingAt: w + 1)
        return name.count >= 4 && !Maker.shortForms.contains(name) ? q - p : nil
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
            if citations {
                // "[citation needed]" is never a reference to read, spaced or not.
                if c == 0x5B, match(Rx.link, p, to) == nil, let m = match(Rx.citation, p, to),
                   glued(p) || (slice as NSString).substring(with: m.range).lowercased().contains("needed") { p += m.range.length; continue }
                if let n = footnoteMark(p, to) { p += n; continue }
            }
            if p == from || !Maker.isWord(u[p - 1]) {
                for (re, value) in lexicon {
                    if let m = match(re, p, to) { put(value, p..<p + m.range.length); p += m.range.length; continue loop }
                }
                if let m = match(Rx.email, p, to) { emitLabels(p, p + m.range.length); p += m.range.length; continue }
                if let m = match(Rx.url, p, to) ?? match(Rx.www, p, to) { p += emitAddress(p, m.range.length); continue }
                if french, Maker.isDigit(c) || c == 0x20AC || c == 0x24 || c == 0xA3, let used = frenchNumber(p, to) { p += used; continue }
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
            case 0x26: put(french ? " et " : " and ", p..<p + 1); p += 1; continue
            case 0x25 where follows(digitBefore: p): put(french ? " pour cent" : " percent", p..<p + 1); p += 1; continue
            case 0xB0:
                let degrees = french ? "degrés" : "degrees"
                if next == 0x43 || next == 0x46, p + 2 >= to || !Maker.isWord(u[p + 2]) {
                    put(" \(degrees) " + (next == 0x43 ? "Celsius" : "Fahrenheit"), p..<p + 2); p += 2
                } else { put(" \(degrees)", p..<p + 1); p += 1 }
                continue
            case 0x7E:
                var q = p + 1
                while q < to, u[q] == 0x20 { q += 1 }
                if q < to, Maker.isDigit(u[q]) || u[q] == 0xA3 || u[q] == 0x24 || u[q] == 0x20AC { put(french ? "environ " : "about ", p..<p + 1); p += 1; continue }
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

    /// Collapses whitespace runs, turns unpunctuated line ends into ". " (not where skipped text was), trims, and shifts
    /// the map to source coordinates.
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
            var j = i, newline = false, skipped = skippedAt.contains(i)
            var a = Int.max, b = Int.min
            while j < units.count, [0x20, 0x09, 0x0A, 0x0D, 0xA0].contains(units[j]) {
                if units[j] == 0x0A || units[j] == 0x0D { newline = true }
                a = min(a, lows[j]); b = max(b, highs[j]); j += 1
                if skippedAt.contains(j) { skipped = true }
            }
            if skipped { newline = false }
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

    // MARK: French

    /// `%` right after a digit; French typography puts a (no-break) space in between.
    func follows(digitBefore p: Int) -> Bool {
        var q = p - 1
        if french { while q >= 0, u[q] == 0x20 || u[q] == 0xA0 || u[q] == 0x202F { q -= 1 } }
        return q >= 0 && Maker.isDigit(u[q])
    }

    /// French spoken form of the date, time, number or amount that starts at p (a digit, or a currency sign before one).
    /// Returns how much source it used, or nil to leave the text to the normal scan.
    mutating func frenchNumber(_ p: Int, _ to: Int) -> Int? {
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : String(decoding: u[r.location..<r.location + r.length], as: UTF16.self)
        }
        typealias F = FrenchNumbers
        if let m = match(Rx.frDate, p, to), let d = Int(group(m, 1)!), let month = Int(group(m, 2)!), (1...31).contains(d), (1...12).contains(month) {
            put(((d == 1 ? ["premier"] : F.cardinal(d)) + [F.months[month - 1]] + F.cardinal(Int(group(m, 3)!)!)).joined(separator: " "), p..<p + m.range.length)
            return m.range.length
        }
        if let m = match(Rx.frTime, p, to), let h = Int(group(m, 1)!), h < 24, let minutes = Int(group(m, 2) ?? group(m, 3) ?? "0"), minutes < 60 {
            let hours = h <= 1 ? [h == 1 ? "une" : "zéro", "heure"] : F.cardinal(h) + ["heures"]
            put((hours + (minutes > 0 ? F.cardinal(minutes) : [])).joined(separator: " "), p..<p + m.range.length)
            return m.range.length
        }
        var start = p, sign: UInt16?   // a currency sign in front: "€45", "$ 4,5"
        if !Maker.isDigit(u[p]) {
            var q = p + 1
            while q < to, u[q] == 0x20 || u[q] == 0xA0 { q += 1 }
            guard q < to, Maker.isDigit(u[q]) else { return nil }
            sign = u[p]; start = q
        }
        guard let m = match(Rx.frNumber, start, to), let whole = group(m, 1) else { return nil }
        let digits = whole.filter { $0.isASCII && $0.isNumber }
        guard digits.count <= 12 else { return nil }   // beyond a thousand billion the engine's own normaliser takes over
        let fraction = group(m, 2)
        var end = start + m.range.length
        let n = fraction == nil ? Int(digits) : nil
        var words = digits.count > 1 && digits.hasPrefix("0") ? F.digits(digits) : F.cardinal(Int(digits)!)
        if let f = fraction {
            let zeros = f.prefix { $0 == "0" }, rest = f.dropFirst(zeros.count)
            words += ["virgule"] + Array(repeating: "zéro", count: zeros.count) + (rest.isEmpty ? [] : rest.count <= 9 ? F.cardinal(Int(rest)!) : F.digits(String(rest)))
        }
        if sign == nil, let n, let o = match(Rx.frOrdinal, end, to) {
            let suffix = group(o, 1)!
            words = F.ordinal(n, feminine: suffix == "re" || suffix == "ère" || suffix == "nde")
            end += o.range.length
        } else if sign == nil, n == 1, match(Rx.frMonth, end, to) != nil {
            words = ["premier"]
        } else if sign == nil, let c = match(Rx.frCurrency, end, to) {
            sign = u[end + c.range.length - 1]; end += c.range.length
        }
        if let sign {
            let noun = sign == 0x20AC ? "euro" : sign == 0x24 ? "dollar" : "livre"
            words.append(n == 1 ? noun : noun + "s")
        }
        let glued = end < to && Maker.isWord(u[end])   // "5km" -> "cinq km"
        put(words.joined(separator: " ") + (glued ? " " : ""), p..<end)
        return end - p
    }
}
