// Text an app exposes to Accessibility but never draws: a screen reader's "Claude responded: …" heading before each
// message, a hover toolbar's "Quick reactions available" hint and its timestamps. A web view's selected text includes
// it, so a read said the opening sentence twice and the toolbar aloud. Pure, so it is tested here; `TextCapture` (app
// target) walks the tree, decides visibility with `Visibility` and places each hidden node with the selection's text
// markers.
import Foundation

public enum HiddenText {
    /// Whether an element's text is drawn on screen, inherited down the tree. Only never-drawn text counts: an inline
    /// chip with `user-select: none` (a session link in a sentence) is on screen and is read.
    public struct Visibility: Equatable, Sendable {
        /// Never drawn: a screen-reader-only node, anything inside one, a toolbar (its buttons' labels, hints and times).
        public var hidden = false

        public init(hidden: Bool = false) { self.hidden = hidden }

        /// Its text belongs in a selection and a highlight.
        public var drawsText: Bool { !hidden }

        /// The visibility of a child of this element, from its role and DOM classes.
        ///
        /// Hidden: a toolbar; the `sr-only` / `visually-hidden` classes; a zero-height box (`h-0`), which is how Claude's
        /// chat hangs a message's hover timestamps below it, unless it grows (`flex-1 h-0` is a flex layout's pane).
        /// Frames are no guide: Chromium reports visible text 1 pt tall while its window is behind others, and the
        /// text inside an `sr-only` clip at full size.
        public func child(role: String?, classes: [String]) -> Visibility {
            var v = self
            if role == "AXToolbar" || classes.contains(where: Self.hiddenClasses.contains) { v.hidden = true }
            if classes.contains("h-0"), !classes.contains(where: Self.growClasses.contains) { v.hidden = true }
            return v
        }

        static let hiddenClasses: Set<String> = ["sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "a11y-hidden"]
        static let growClasses: Set<String> = ["flex-1", "grow", "flex-grow", "flex-auto"]
    }

    /// `text` without the UTF-16 `ranges` (clamped, overlaps merged), and how many units went. A cut between two
    /// non-space characters leaves one space, so the messages either side of a hidden toolbar do not run together.
    public static func cut(_ text: String, ranges: [Range<Int>]) -> (text: String, removed: Int) {
        let u = Array(text.utf16)
        var merged: [Range<Int>] = []
        for r in ranges.map({ max(0, $0.lowerBound)..<min(u.count, max($0.upperBound, max(0, $0.lowerBound))) })
            .filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
            else { merged.append(r) }
        }
        guard !merged.isEmpty else { return (text, 0) }
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 }
        var out: [UInt16] = [], a = 0, removed = 0
        for r in merged {
            out += u[a..<r.lowerBound]
            removed += r.count
            if let before = out.last, r.upperBound < u.count, !isSpace(before), !isSpace(u[r.upperBound]) { out.append(0x20); removed -= 1 }
            a = r.upperBound
        }
        out += u[a...]
        return (String(decoding: out, as: UTF16.self), removed)
    }

    /// Fallback when the offsets cannot be trusted: each of `strings`, in order, cut at its first occurrence after the
    /// previous one. A string not found is skipped; whitespace-only strings are never cut.
    public static func cut(_ text: String, strings: [String]) -> (text: String, removed: Int) {
        let ns = text as NSString
        var ranges: [Range<Int>] = [], from = 0
        for s in strings where !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let r = ns.range(of: s, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { continue }
            ranges.append(r.location..<r.location + r.length)
            from = r.location + r.length
        }
        return cut(text, ranges: ranges)
    }

    /// Safety net for what the tree walk missed: a screen reader heading straight before the text it repeats,
    /// "Claude responded: X" or "You said: X" followed by X (a long heading is cut short with "…", so then X's
    /// opening). Returns the headings' ranges; text that merely mentions "You said:" is never followed by a copy of itself.
    public static func repeatedHeadings(_ text: String) -> [Range<Int>] {
        let u = Array(text.utf16).map(plainQuote)   // the heading has straight quotes where the message has curly ones
        var found: [Range<Int>] = []
        for prefix in prefixes {
            let p = Array(prefix.utf16)
            var i = 0
            while i + p.count <= u.count {
                guard Array(u[i..<i + p.count]) == p else { i += 1; continue }
                let a = i + p.count
                // The heading's own text runs from a to e; the message body, starting at e, opens with the same text.
                var hit: Int?
                var e = a + minimum
                while hit == nil, e <= min(u.count, a + 600) {
                    var h = e - a
                    if u[e - 1] == 0x2026 { h -= 1 }   // "…": the heading was cut short, the body goes on
                    if h >= minimum, e + h <= u.count, u[a..<a + h].elementsEqual(u[e..<e + h]) { hit = e }
                    e += 1
                }
                if let hit { found.append(i..<hit); i = hit } else { i += 1 }
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// After the tree cut (`removed` units so far), or alone for text the tree cannot reach (an Edit ▸ Copy, which
    /// Chromium serialises with its screen reader text): the repeated headings go, and after any cut the button
    /// placeholders (U+FFFC) too. Returns the text and the total removed.
    public static func safetyNet(_ text: String, removed: Int = 0) -> (text: String, removed: Int) {
        var (out, n) = cut(text, ranges: repeatedHeadings(text))
        n += removed
        if n > 0 { let objects = cut(out, ranges: objectReplacements(out)); (out, n) = (objects.text, n + objects.removed) }
        return (out, n)
    }

    public static let prefixes = ["Claude responded: ", "You said: "]

    /// ’ ‘ as ', “ ” as ": the same length, so offsets hold.
    public static func plainQuote(_ c: UInt16) -> UInt16 {
        c == 0x2018 || c == 0x2019 ? 0x27 : c == 0x201C || c == 0x201D ? 0x22 : c
    }

    /// The ranges of U+FFFC, the placeholder Chromium puts in a selection's text for each button or image.
    public static func objectReplacements(_ text: String) -> [Range<Int>] {
        text.utf16.enumerated().filter { $0.element == 0xFFFC }.map { $0.offset..<$0.offset + 1 }
    }
    /// Shortest heading text taken as a repeat (shorter ones could be ordinary repetition: "No. No.").
    static let minimum = 12
}
