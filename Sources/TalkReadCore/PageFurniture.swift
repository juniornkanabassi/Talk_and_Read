// A PDF's page furniture: running headers, footers and page numbers, found so a read can skip them (Speechify's "skip
// headers and footers"). Text stays as it is on screen; only what is spoken changes.
import Foundation

public enum PageFurniture {
    /// Lines looked at on each page, from the top and from the bottom.
    static let edgeLines = 2
    /// What a page number looks like once its numbers are "#": "#", "page #", "p. #", "- # -", "# of #", "#/#".
    static let pageNumber = try! NSRegularExpression(pattern: "^(?:page |p\\. ?)?[-–—]? ?# ?[-–—]?(?: ?(?:of|/) ?#)?$")
    /// A line longer than this is body text, never furniture.
    static let maxLength = 100

    /// The ranges (UTF-16, in `text`) of every furniture line. `pageStarts`: where each page begins in `text`, as the
    /// importer joined them (pages separated by "\n\n").
    ///
    /// Two kinds count, both only in the first or last two lines of a page (one on a page of under 8 lines), never an
    /// answer option, list item or sentence, and only with three pages or more:
    /// - a page number ("7", "Page 3 of 40", "- 7 -") that moves in step with the page. A numbered line with other words
    ///   ("Question 2", "Matchday 3", even a running head like "12 Contract Law") is read: one question per page also
    ///   counts with the page.
    /// - the same line in the same place (the same edge, the same line from it) on at least three pages and two fifths
    ///   of them (a journal title, alternating running heads). A second line from an edge counts only under an outer line
    ///   that is furniture too, so "Facts" under each case name, or a slide title on a few slides, is read.
    public static func ranges(_ text: String, pageStarts: [Int]) -> [Range<Int>] {
        let u = Array(text.utf16)
        guard pageStarts.count >= 3 else { return [] }
        let needed = max(3, (pageStarts.count * 2 + 4) / 5)

        /// An edge line: where it sits (0, 1 from the top; -1, -2 from the bottom), its text lower-cased with spaces
        /// collapsed, that text with every number as "#", and its first number.
        struct Line { let page: Int; let slot: Int; let range: Range<Int>; let exact: String; let shape: String; let number: Int? }
        var lines: [Line] = []
        for (page, start) in pageStarts.enumerated() {
            let end = page + 1 < pageStarts.count ? max(start, pageStarts[page + 1] - 2) : u.count
            guard start <= end, end <= u.count else { continue }
            var all: [Range<Int>] = []   // the page's non-empty lines
            var a = start
            for i in start...end where i == end || u[i] == 0x0A || u[i] == 0x0D {
                if let r = trimmed(u, a..<i) { all.append(r) }
                a = i + 1
            }
            // A short page (a slide, one exam question) gets one edge line a side, so its body is not all "edge".
            let n = all.count < 8 ? 1 : edgeLines
            for (i, r) in all.enumerated() where (i < n || i >= all.count - n) && r.count <= maxLength {
                let slot = i < n ? i : i - all.count
                let s = String(decoding: u[r], as: UTF16.self).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let shape = s.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
                // An answer option or list item ("A. Yes", "(b) No", "3) Cost", "• None", "- 3 points") is body, however
                // often it repeats; only a whole page-number shape ("- 7 -") starting with a dash is not a bullet.
                // PDF bullet glyphs often lose the space after them when extracted.
                guard s.range(of: "^(?:\\(?([a-h]|[ivx]{1,4}|[0-9]{1,2})[.)] |[•◦▪▫●○■□‣⁃∙►▶➢✓✔] ?|[*+] )", options: .regularExpression) == nil,
                      s.range(of: "^[-–—] ", options: .regularExpression) == nil
                        || pageNumber.firstMatch(in: shape, range: NSRange(shape.startIndex..., in: shape)) != nil else { continue }
                let first = s.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).first
                lines.append(Line(page: page, slot: slot, range: r, exact: s,
                                  shape: shape,
                                  number: first.flatMap { $0.count <= 4 ? Int($0) : nil }))
            }
        }

        var found = Set<Range<Int>>()
        // A page number whose (first) number is the page's index plus a fixed offset ("Page 3 of 40" follows by its 3).
        let numbers = lines.filter { l in
            l.number != nil && pageNumber.firstMatch(in: l.shape, range: NSRange(l.shape.startIndex..., in: l.shape)) != nil
        }
        for group in Dictionary(grouping: numbers, by: \.shape).values {
            for same in Dictionary(grouping: group, by: { $0.number! - $0.page }).values where Set(same.map(\.page)).count >= needed {
                found.formUnion(same.map(\.range))
            }
        }
        // The same line in the same place on many pages: the outer lines first, then the second line from each edge on
        // pages whose outer line at that edge is such a repeated line too (a two-line running head; a heading above a
        // page number is body). A repeated sentence ("Explain your answer.") is an instruction.
        let place = Dictionary(lines.map { ([$0.page, $0.slot], $0.range) }, uniquingKeysWith: { a, _ in a })
        var repeated = Set<Range<Int>>()
        for slots in [[0, -1], [1, -2]] {
            let candidates = lines.filter { l in
                guard slots.contains(l.slot), !(l.exact.last.map { ".?!".contains($0) } ?? false) else { return false }
                return l.slot == 0 || l.slot == -1 || place[[l.page, l.slot > 0 ? 0 : -1]].map(repeated.contains) == true
            }
            for group in Dictionary(grouping: candidates, by: { "\($0.slot) \($0.exact)" }).values where Set(group.map(\.page)).count >= needed {
                repeated.formUnion(group.map(\.range))
            }
        }
        found.formUnion(repeated)
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// `r` without leading and trailing spaces; nil when nothing is left.
    private static func trimmed(_ u: [UInt16], _ r: Range<Int>) -> Range<Int>? {
        var a = r.lowerBound, b = r.upperBound
        while a < b, [0x20, 0x09, 0xA0].contains(u[a]) { a += 1 }
        while b > a, [0x20, 0x09, 0xA0].contains(u[b - 1]) { b -= 1 }
        return a < b ? a..<b : nil
    }
}
