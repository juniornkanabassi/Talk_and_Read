// Spoken words -> source word indices (monotonic DP). Owned by WP1.
import Foundation

public enum Alignment {
    /// Monotonic many-to-one map from spoken words to source word indices (nil = unmatched). Case/punct-insensitive,
    /// digits match their spoken English words, initialisms match letter-by-letter, hyphen parts match the compound.
    ///
    /// Needleman-Wunsch style: +10 per matched spoken word, -4 per skipped word on either side, no substitutions, free
    /// leading and trailing source words. Many-to-one matches: a run of number words for a digit token (cardinals,
    /// ordinals, years, decimals, a following "pounds"/"percent"/"times"), single letters for an all-caps token; one spoken
    /// word for several single-letter tokens ("fbi" for F, B, I).
    // ponytail: each row only looks at the source words from 10 behind to 50 ahead of the previous row's best column (O(n*60)
    // not O(n*m)); a gap of more than 50 words between the two texts loses the alignment past it. Callers pass one chunk.
    public static func assign(spoken: [String], source: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: spoken.count)
        let sp = parts(spoken), tp = parts(source)
        guard !sp.isEmpty, !tp.isEmpty else { return result }
        let map = Aligner(sp: sp, tp: tp).align()
        for (q, target) in map.enumerated() {
            if let target, result[sp[q].owner] == nil { result[sp[q].owner] = tp[target].owner }
        }
        return result
    }

    // MARK: normalising

    private struct Part { let raw: String; let norm: String; let owner: Int }

    private static let hyphens: Set<Character> = ["-", "‐", "‑", "–", "—"]

    /// Words split at hyphens, each part remembering the word it came from.
    private static func parts(_ words: [String]) -> [Part] {
        var out: [Part] = []
        for (i, w) in words.enumerated() {
            for piece in w.split(whereSeparator: hyphens.contains) { out.append(Part(raw: String(piece), norm: norm(String(piece)), owner: i)) }
        }
        return out
    }

    private static let wordCharacters = CharacterSet.alphanumerics
    private static let edgeCharacters = CharacterSet.punctuationCharacters.union(.symbols)

    /// Lowercase, diacritics folded, possessive 's and every non-alphanumeric dropped.
    static func norm(_ s: String) -> String {
        if s.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }) { return s }   // plain lowercase already
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).replacingOccurrences(of: "’", with: "'")
        if t.hasSuffix("'s") { t.removeLast(2) }
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { wordCharacters.contains($0) }))
    }

    // MARK: numbers

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000, "trillion": 1_000_000_000_000]
    private static let irregularOrdinals = ["first": "one", "second": "two", "third": "three", "fifth": "five", "eighth": "eight", "ninth": "nine", "twelfth": "twelve"]
    private static let unitWords: Set<String> = ["pounds", "pound", "dollars", "dollar", "euros", "euro", "pence", "penny", "cents", "cent", "percent", "degrees", "degree"]

    private static func isCardinal(_ w: String) -> Bool { units[w] != nil || tens[w] != nil || w == "hundred" || scales[w] != nil }

    /// "twenty first" -> "one" for "first"; nil when `w` is not an ordinal.
    private static func ordinalBase(_ w: String) -> String? {
        if let b = irregularOrdinals[w] { return b }
        if w.hasSuffix("ieth") { let b = String(w.dropLast(4)) + "y"; return tens[b] != nil ? b : nil }
        if w.hasSuffix("th") { let b = String(w.dropLast(2)); return isCardinal(b) ? b : nil }
        return nil
    }

    private static func isNumberWord(_ w: String) -> Bool {
        isCardinal(w) || w == "and" || w == "oh" || w == "point" || ordinalBase(w) != nil
    }

    /// Value of well-formed English number words ("one hundred and five"); the last word may be an ordinal.
    private static func cardinal(_ words: ArraySlice<String>) -> Int? {
        var ws = Array(words)
        guard let last = ws.last else { return nil }
        if let b = ordinalBase(last) { ws[ws.count - 1] = b }
        var total = 0, current = 0, lastScale = Int.max, prev = ""
        for w in ws {
            defer { prev = w }
            if w == "and" {
                guard prev == "hundred" || scales[prev] != nil else { return nil }
                continue
            }
            if let v = units[w] {
                if v == 0 { return ws.count == 1 ? 0 : nil }
                guard current % 100 == 0 || (v < 10 && current % 100 >= 20 && current % 10 == 0) else { return nil }
                current += v
            } else if let v = tens[w] {
                guard current % 100 == 0 else { return nil }
                current += v
            } else if w == "hundred" {
                guard current > 0, current < 100 else { return nil }
                current *= 100
            } else if let scale = scales[w] {
                guard current > 0, scale < lastScale else { return nil }
                total += current * scale; current = 0; lastScale = scale
            } else { return nil }
        }
        return prev == "and" ? nil : total + current
    }

    /// "nineteen ninety nine" -> 1999, "twenty twenty six" -> 2026, "nineteen oh five" -> 1905.
    private static func year(_ ws: ArraySlice<String>) -> Int? {
        guard ws.count >= 2 else { return nil }
        for cutAt in (ws.startIndex + 1)..<ws.endIndex {
            guard let a = cardinal(ws[ws.startIndex..<cutAt]), (10...99).contains(a) else { continue }
            let rest = ws[cutAt...]
            if rest.first == "oh" || rest.first == "zero" {
                if rest.count == 2, let b = units[rest[rest.startIndex + 1]], (1...9).contains(b) { return a * 100 + b }
            } else if let b = cardinal(rest), (10...99).contains(b) { return a * 100 + b }
        }
        return nil
    }

    /// "two point five" -> "2.5".
    private static func decimal(_ ws: ArraySlice<String>) -> String? {
        guard let point = ws.firstIndex(of: "point"), point > ws.startIndex, point + 1 < ws.endIndex,
              let whole = cardinal(ws[ws.startIndex..<point]) else { return nil }
        var digits = ""
        for w in ws[(point + 1)...] {
            guard let d = w == "oh" ? 0 : units[w], d < 10 else { return nil }
            digits += String(d)
        }
        return "\(whole).\(digits)"
    }

    /// Every digit string the spoken number words can mean.
    private static func readings(_ ws: ArraySlice<String>) -> [String] {
        var out: [String] = []
        if let v = cardinal(ws) { out.append(String(v)) }
        if let v = year(ws) { out.append(String(v)) }
        if let v = decimal(ws) { out.append(v) }
        return out
    }

    /// "£45", "21st", "2.5", "1,000", "3x" -> canonical digits, and whether it carries a times sign.
    private static func numeric(_ raw: String) -> (canon: String, times: Bool)? {
        guard raw.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        let t = Array(raw.trimmingCharacters(in: edgeCharacters).replacingOccurrences(of: ",", with: "").unicodeScalars)
        var i = 0
        while i < t.count, t[i].properties.numericType == .decimal, t[i].isASCII { i += 1 }
        guard i > 0 else { return nil }
        if i + 1 < t.count, t[i] == ".", t[i + 1].isASCII, t[i + 1].properties.numericType == .decimal {
            i += 1
            while i < t.count, t[i].isASCII, t[i].properties.numericType == .decimal { i += 1 }
        }
        let suffix = String(String.UnicodeScalarView(t[i...])).lowercased()
        guard ["", "st", "nd", "rd", "th", "x"].contains(suffix) else { return nil }
        return (String(String.UnicodeScalarView(t[..<i])), suffix == "x")
    }

    // MARK: the DP

    private struct Aligner {
        let sp: [Part], tp: [Part]
        let sid: [Int], tid: [Int]
        let run: [Int]                               // spoken: length of the number-word run starting here
        let tnum: [(canon: String, times: Bool)?]    // source: digit token
        let tinit: [[Int]?]                          // source: letter ids of an all-caps token
        let single: [Bool]                           // source: one letter
        let special: [Bool]                          // source: anything beyond a plain word (digits, initialism, letter)
        let isX: [Bool], isTimes: [Bool]
        let spokenLength: [Int]

        init(sp: [Part], tp: [Part]) {
            self.sp = sp; self.tp = tp
            var ids: [String: Int] = [:]
            func id(_ s: String) -> Int { s.isEmpty ? -1 : (ids[s] ?? { ids[s] = ids.count; return ids.count - 1 }()) }
            sid = sp.map { id($0.norm) }
            tid = tp.map { id($0.norm) }
            var run = [Int](repeating: 0, count: sp.count + 1)
            for i in stride(from: sp.count - 1, through: 0, by: -1) where isNumberWord(sp[i].norm) { run[i] = run[i + 1] + 1 }
            self.run = run
            let nums = tp.map { numeric($0.raw) }
            let inits: [[Int]?] = tp.map { part in
                guard part.raw.utf8.count <= 12, part.raw.first?.isUppercase == true else { return nil }
                let letters = part.raw.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                guard (2...6).contains(letters.count), letters.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return nil }
                return letters.map { id(norm(String($0))) }
            }
            let singles = tp.map { $0.norm.count == 1 && $0.raw.first?.isLetter == true }
            tnum = nums; tinit = inits; single = singles
            special = tp.indices.map { nums[$0] != nil || inits[$0] != nil || singles[$0] }
            isX = tp.map { $0.norm == "x" }
            isTimes = sp.map { $0.norm == "times" || $0.norm == "by" }
            spokenLength = sp.map { $0.norm.count }
        }

        /// For each spoken part, the source part it belongs to.
        @_optimize(speed)   // this loop is the whole cost; keeps `swift test` (debug) inside the 200 ms budget too
        func align() -> [Int?] {
            let n = sp.count, m = tp.count
            let band = 50, stride = 2 * band + 2, none = Int.min / 4, cells = (n + 1) * stride
            // Raw buffers: this loop is the whole cost, and debug builds (swift test) must stay fast too.
            let score = UnsafeMutablePointer<Int>.allocate(capacity: cells)
            score.initialize(repeating: none, count: cells)
            let back = UnsafeMutablePointer<UInt32>.allocate(capacity: cells)   // kind | spoken words << 8 | source words << 16
            back.initialize(repeating: 0, count: cells)
            let lo = UnsafeMutablePointer<Int>.allocate(capacity: n + 1), hi = UnsafeMutablePointer<Int>.allocate(capacity: n + 1)
            lo.initialize(repeating: 0, count: n + 1); hi.initialize(repeating: 0, count: n + 1)
            defer { score.deallocate(); back.deallocate(); lo.deallocate(); hi.deallocate() }
            hi[0] = min(m, band)
            for j in 0...hi[0] { score[j] = 0 }   // free start: the spoken text may begin at any early source word
            var memo: [Int: [String]] = [:]
            func spokenReadings(_ si: Int, _ k: Int) -> [String] {
                if let r = memo[si * 16 + k] { return r }
                let r = readings(sp[si..<si + k].map(\.norm)[...])
                memo[si * 16 + k] = r
                return r
            }
            sid.withUnsafeBufferPointer { sid in tid.withUnsafeBufferPointer { tid in special.withUnsafeBufferPointer { special in
            for i in 1...n {
                let prevLo = lo[i - 1], prevHi = hi[i - 1], prevRow = (i - 1) * stride - prevLo
                var centre = prevLo, top = none
                for j in prevLo...prevHi where score[prevRow + j] > top { top = score[prevRow + j]; centre = j }
                let low = max(0, centre - 10), high = min(m, centre + band)   // the path only ever moves forward: little room behind it
                lo[i] = low; hi[i] = high
                let row = i * stride - low
                let w = sid[i - 1]
                for j in low...high {
                    var best = none, kind: UInt32 = 0
                    if j >= prevLo, j <= prevHi { let up = score[prevRow + j]; if up > none { best = up - 4; kind = 1 } }
                    if j > low { let left = score[row + j - 1] - 4; if left > best { best = left; kind = 2 } }
                    if j > 0 {
                        if j > prevLo, j <= prevHi + 1, w >= 0, w == tid[j - 1] {
                            let d = score[prevRow + j - 1]
                            if d > none, d + 10 > best { best = d + 10; kind = 3 | 1 << 8 | 1 << 16 }
                        }
                        // The rare cells: digits, initialisms, single letters on the source side (many-to-one matches).
                        if special[j - 1] {
                            func offer(_ fromRow: Int, _ fromCol: Int, _ gain: Int, _ spokenN: Int, _ sourceN: Int) {
                                guard fromCol >= lo[fromRow], fromCol <= hi[fromRow] else { return }
                                let v = score[fromRow * stride + fromCol - lo[fromRow]]
                                if v > none, v + gain > best { best = v + gain; kind = 3 | UInt32(spokenN) << 8 | UInt32(sourceN) << 16 }
                            }
                            if isX[j - 1] && isTimes[i - 1] { offer(i - 1, j - 1, 10, 1, 1) }
                            if let num = tnum[j - 1] {
                                for total in 1...min(i, 14) {
                                    let si = i - total
                                    if !num.times, run[si] >= total, spokenReadings(si, total).contains(num.canon) { offer(si, j - 1, 10 * total, total, 1) }
                                    // the number plus one unit word after it ("forty five pounds", "fifty percent", "five times")
                                    if total > 1, run[si] >= total - 1, num.times ? isTimes[i - 1] || sp[i - 1].norm == "x" : unitWords.contains(sp[i - 1].norm),
                                       spokenReadings(si, total - 1).contains(num.canon) { offer(si, j - 1, 10 * (total - 1) + 9, total, 1) }
                                }
                            }
                            if let letters = tinit[j - 1], i >= letters.count, (0..<letters.count).allSatisfy({ sid[i - letters.count + $0] == letters[$0] }) {
                                offer(i - letters.count, j - 1, 10 * letters.count, letters.count, 1)
                            }
                            if w >= 0, spokenLength[i - 1] >= 2 {
                                for count in 2...max(2, min(6, j)) where count <= j && spokenLength[i - 1] == count && (j - count..<j).allSatisfy({ single[$0] })
                                    && (j - count..<j).map({ tp[$0].norm }).joined() == sp[i - 1].norm { offer(i - 1, j - count, 10, 1, count) }
                            }
                        }
                    }
                    score[row + j] = best; back[row + j] = kind
                }
            }
            } } }
            var i = n, j = lo[n], top = none
            for c in lo[n]...hi[n] where score[n * stride + c - lo[n]] > top { top = score[n * stride + c - lo[n]]; j = c }
            var out = [Int?](repeating: nil, count: n)
            while i > 0 {
                let b = back[i * stride + j - lo[i]]
                switch b & 0xFF {
                case 1: i -= 1
                case 2: j -= 1
                case 3:
                    let ks = Int(b >> 8 & 0xFF), kt = Int(b >> 16 & 0xFF)
                    for q in (i - ks)..<i { out[q] = j - kt }
                    i -= ks; j -= kt
                default: i = 0
                }
            }
            return out
        }
    }
}
