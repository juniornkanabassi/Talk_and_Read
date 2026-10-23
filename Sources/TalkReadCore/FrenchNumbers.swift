// French number words, both directions: digits -> words for `Speakable`, words -> digit strings for `Alignment`.
// Standard (France) forms: soixante-dix, quatre-vingts, quatre-vingt-dix. V-B.
import Foundation

enum FrenchNumbers {
    static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]

    private static let units = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix",
                                "onze", "douze", "treize", "quatorze", "quinze", "seize"]
    private static let tens = [2: "vingt", 3: "trente", 4: "quarante", 5: "cinquante", 6: "soixante"]

    // MARK: digits -> words

    // ponytail: words are separated by spaces ("quatre vingt dix neuf"), not hyphens: the same sound, and one engine
    // word per number word, which keeps Kokoro's group-to-word pairing one to one.
    static func cardinal(_ n: Int) -> [String] {
        if n == 0 { return ["zéro"] }
        var out: [String] = [], rest = n
        for (scale, name) in [(1_000_000_000, "milliard"), (1_000_000, "million")] {
            let k = rest / scale
            rest %= scale
            if k > 0 { out += below1000(k, plural: true) + [k > 1 ? name + "s" : name] }
        }
        let k = rest / 1000
        rest %= 1000
        if k > 0 { out += (k == 1 ? [] : below1000(k, plural: false)) + ["mille"] }
        if rest > 0 { out += below1000(rest, plural: true) }
        return out
    }

    /// "premier"/"première" for 1, else the cardinal with its last word turned into "-ième".
    static func ordinal(_ n: Int, feminine: Bool = false) -> [String] {
        if n == 1 { return [feminine ? "première" : "premier"] }
        var w = cardinal(n)
        var last = w.removeLast()
        if last.hasSuffix("s") && last != "trois" { last.removeLast() }   // vingts, cents, millions
        switch last {
        case "cinq": last = "cinquième"
        case "neuf": last = "neuvième"
        default: last = last.hasSuffix("e") ? String(last.dropLast()) + "ième" : last + "ième"
        }
        return w + [last]
    }

    /// Digits one by one ("007", phone numbers).
    static func digits(_ s: String) -> [String] { s.compactMap { $0.wholeNumberValue }.map { units[$0] } }

    private static func below1000(_ k: Int, plural: Bool) -> [String] {
        let h = k / 100, r = k % 100
        var out: [String] = []
        if h > 0 { out += (h == 1 ? [] : [units[h]]) + [h > 1 && r == 0 && plural ? "cents" : "cent"] }
        if r > 0 { out += below100(r, plural: plural) }
        return out
    }

    private static func upTo19(_ m: Int) -> [String] { m <= 16 ? [units[m]] : ["dix", units[m - 10]] }

    private static func below100(_ r: Int, plural: Bool) -> [String] {
        if r < 20 { return upTo19(r) }
        if r < 70 {
            let u = r % 10
            return u == 0 ? [tens[r / 10]!] : u == 1 ? [tens[r / 10]!, "et", "un"] : [tens[r / 10]!, units[u]]
        }
        if r < 80 { return ["soixante"] + (r == 71 ? ["et", "onze"] : upTo19(r - 60)) }
        return ["quatre", r == 80 && plural ? "vingts" : "vingt"] + (r == 80 ? [] : upTo19(r - 80))
    }

    // MARK: words -> digits

    private static let wordValue: [String: Int] = {
        var d: [String: Int] = ["une": 1, "dix": 10]
        for (i, w) in units.enumerated() { d[fold(w)] = i }
        for (t, w) in tens { d[w] = t * 10 }
        return d
    }()
    private static let scales: [String: Int] = ["mille": 1000, "million": 1_000_000, "millions": 1_000_000,
                                                "milliard": 1_000_000_000, "milliards": 1_000_000_000]

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    static func isNumberWord(_ w: String) -> Bool {
        wordValue[w] != nil || scales[w] != nil || w == "cent" || w == "cents" || w == "vingts" || w == "et" || w == "virgule" || ordinalBase(w) != nil
    }

    /// "deuxième" -> "deux", "premiere" -> "un", "cinquièmes" -> "cinq"; nil when `w` is not an ordinal.
    static func ordinalBase(_ w: String) -> String? {
        switch w { case "premier", "premiere", "premiers", "premieres": return "un"
        case "second", "seconde", "seconds", "secondes": return "deux"
        default: break }
        var s = w
        if s.hasSuffix("s") { s.removeLast() }
        guard s.hasSuffix("ieme") else { return nil }
        let stem = String(s.dropLast(4))
        for candidate in [stem == "cinqu" ? "cinq" : stem == "neuv" ? "neuf" : stem, stem + "e"] where wordValue[candidate] != nil || candidate == "cent" || scales[candidate] != nil {
            return candidate
        }
        return nil
    }

    /// Value of well-formed French number words, folded and lowercase ("quatre vingt dix neuf" -> 99); the last may be an ordinal.
    static func cardinalValue(_ words: ArraySlice<String>) -> Int? {
        var ws = Array(words)
        guard let last = ws.last else { return nil }
        if let b = ordinalBase(last) { ws[ws.count - 1] = b }
        var total = 0, current = 0, lastScale = Int.max, prev = ""
        for w in ws {
            defer { prev = w }
            if w == "et" { guard !prev.isEmpty, prev != "et" else { return nil }; continue }
            if w == "cent" || w == "cents" {
                guard (1..<100).contains(current) || current == 0 else { return nil }
                current = max(current, 1) * 100
            } else if w == "vingt" || w == "vingts", prev == "quatre", current % 100 == 4 {
                current += 76
            } else if let scale = scales[w] {
                guard scale < lastScale else { return nil }
                total += max(current, 1) * scale; current = 0; lastScale = scale
            } else if let v = wordValue[w] {
                let low = current % 100
                if v == 0 { guard words.count == 1 else { return nil }; return 0 }
                if v >= 20 || v == 10 { guard low == 0 || (v == 10 && (low == 60 || low == 80)) else { return nil } }
                else if v >= 11 { guard low == 0 || low == 60 || low == 80 else { return nil } }
                else { guard low % 10 == 0, low != 10 || v >= 7 else { return nil } }
                current += v
            } else { return nil }
        }
        return prev == "et" || prev.isEmpty ? nil : total + current
    }

    /// Every digit string the French words can mean, "quatre virgule deux" -> "4.2".
    static func readings(_ words: ArraySlice<String>) -> [String] {
        var out: [String] = []
        if let v = cardinalValue(words) { out.append(String(v)) }
        if let point = words.firstIndex(of: "virgule"), point > words.startIndex, point + 1 < words.endIndex,
           let whole = cardinalValue(words[words.startIndex..<point]) {
            let tail = words[(point + 1)...]
            let zeros = tail.prefix { $0 == "zero" }
            let rest = tail.dropFirst(zeros.count)
            let zeroDigits = String(repeating: "0", count: zeros.count)
            if rest.isEmpty { out.append("\(whole).\(zeroDigits)") }
            else if let f = cardinalValue(rest) { out.append("\(whole).\(zeroDigits)\(f)") }
            if tail.allSatisfy({ wordValue[$0].map { $0 < 10 } ?? false }) {
                out.append("\(whole)." + tail.map { String(wordValue[$0]!) }.joined())
            }
        }
        return out
    }
}
