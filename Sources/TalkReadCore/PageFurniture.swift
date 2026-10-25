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
    /// answer option or list item, and only with three pages or more:
    /// the same line on at least three pages and a fifth of them (a journal title, a running head), and a page number
    /// ("7", "Page 3 of 40", "- 7 -") that moves in step with the page. A numbered line with other words ("Question 2",
    /// "Matchday 3", even a running head like "12 Contract Law") is read: one question per page also counts with the page.
    public static func ranges(_ text: String, pageStarts: [Int]) -> [Range<Int>] {
        let u = Array(text.utf16)
        guard pageStarts.count >= 3 else { return [] }
        let needed = max(3, (pageStarts.count + 4) / 5)

        /// An edge line: its text lower-cased with spaces collapsed, that text with every number as "#", and its first number.
        struct Line { let page: Int; let range: Range<Int>; let exact: String; let shape: String; let number: Int? }
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
            let edges = Set(all.prefix(n).map(\.lowerBound) + all.suffix(n).map(\.lowerBound))
            for r in all where edges.contains(r.lowerBound) && r.count <= maxLength {
                let s = String(decoding: u[r], as: UTF16.self).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                // An answer option or list item ("A. Yes", "(b) No", "3) Cost", "• None") is body, however often it repeats;
                // "- 7 -" is a page number, not a bullet.
                guard s.range(of: "^(?:\\(?([a-h]|[ivx]{1,4}|[0-9]{1,2})[.)] |[•◦▪*+] |[-–—] (?![0-9]))", options: .regularExpression) == nil else { continue }
                let first = s.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).first
                lines.append(Line(page: page, range: r, exact: s,
                                  shape: s.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression),
                                  number: first.flatMap { $0.count <= 4 ? Int($0) : nil }))
            }
        }

        var found: [Range<Int>] = []
        // The same line on many pages.
        // A repeated sentence ("Explain your answer.") is an instruction, not a running head or footer.
        let prose = Set(lines.filter { $0.exact.last.map { ".?!".contains($0) } ?? false }.map(\.exact))
        for group in Dictionary(grouping: lines, by: \.exact).values where Set(group.map(\.page)).count >= needed && !prose.contains(group[0].exact) {
            found += group.map(\.range)
        }
        // A page number whose (first) number is the page's index plus a fixed offset ("Page 3 of 40" follows by its 3).
        let numbers = lines.filter { l in
            l.number != nil && pageNumber.firstMatch(in: l.shape, range: NSRange(l.shape.startIndex..., in: l.shape)) != nil
        }
        for group in Dictionary(grouping: numbers, by: \.shape).values {
            for same in Dictionary(grouping: group, by: { $0.number! - $0.page }).values where Set(same.map(\.page)).count >= needed {
                found += same.map(\.range)
            }
        }
        return Array(Set(found)).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// `r` without leading and trailing spaces; nil when nothing is left.
    private static func trimmed(_ u: [UInt16], _ r: Range<Int>) -> Range<Int>? {
        var a = r.lowerBound, b = r.upperBound
        while a < b, [0x20, 0x09, 0xA0].contains(u[a]) { a += 1 }
        while b > a, [0x20, 0x09, 0xA0].contains(u[b - 1]) { b -= 1 }
        return a < b ? a..<b : nil
    }
}
