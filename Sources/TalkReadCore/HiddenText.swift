// Text an app exposes to Accessibility but never draws: a screen reader's "Claude responded: …" heading before each
// message, a hover toolbar's "Quick reactions available" hint and its timestamps. A web view's selected text includes
// it, so a read said the opening sentence twice and the toolbar aloud. Pure, so it is tested here; `TextCapture` (app
// target) walks the tree, decides visibility with `Visibility` and places each hidden node with the selection's text
// markers (`place`, `locate`). Every rule leans towards keeping text: a visible word cut is worse than a hidden one read.
import Foundation

public enum HiddenText {
    /// Whether an element's text is drawn on screen, inherited down the tree. Only never-drawn text counts: an inline
    /// chip with `user-select: none` (a session link in a sentence) is on screen and is read.
    public struct Visibility: Equatable, Sendable {
        /// Not read: a screen-reader-only node, anything inside one, and in Claude its hover toolbar and timestamps.
        public var hidden = false

        public init(hidden: Bool = false) { self.hidden = hidden }

        /// Its text belongs in a selection and a highlight.
        public var drawsText: Bool { !hidden }

        /// The visibility of a child of this element, from its role and DOM classes.
        ///
        /// Anywhere: the `sr-only` / `visually-hidden` classes, unless a `not-sr-only` variant shows the node somewhere.
        /// In Claude (`claude`), whose chat is known: its message toolbar (shown on hover), and a zero-height box (`h-0`),
        /// which is how it hangs a message's hover timestamps below it, unless anything else sets its height
        /// (`min-h-10`, `md:h-auto`, `group-hover:h-auto`, `size-4`), it grows (`flex-1 h-0` is a flex layout's pane)
        /// or it lets its content show (`overflow-visible`). Elsewhere a toolbar or an `h-0` box may well be drawn.
        /// Frames are no guide: Chromium reports visible text 1 pt tall while its window is behind others, and the
        /// text inside an `sr-only` clip at full size.
        public func child(role: String?, classes: [String], claude: Bool) -> Visibility {
            var v = self
            let bases = classes.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            if claude, role == "AXToolbar" { v.hidden = true }
            if classes.contains(where: Self.hiddenClasses.contains), !bases.contains("not-sr-only") { v.hidden = true }
            if claude, classes.contains("h-0"),
               !zip(classes, bases).contains(where: { full, base in
                   full != "h-0" && ["h-", "min-h-", "max-h-", "size-"].contains(where: base.hasPrefix) }),
               !bases.contains(where: Self.showClasses.contains) { v.hidden = true }
            return v
        }

        static let hiddenClasses: Set<String> = ["sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "a11y-hidden"]
        static let showClasses: Set<String> = ["flex-1", "grow", "flex-grow", "flex-auto", "overflow-visible", "overflow-y-visible"]
    }

    /// `text` without the UTF-16 `ranges` (clamped at both ends, overlaps merged). `removed` counts the units cut; a cut
    /// between two non-space characters leaves one space, so the messages either side of a hidden toolbar do not run
    /// together, which `removed` does not subtract.
    public static func cut(_ text: String, ranges: [Range<Int>]) -> (text: String, removed: Int) {
        let u = Array(text.utf16)
        var merged: [Range<Int>] = []
        for r in ranges.map({ min(max(0, $0.lowerBound), u.count)..<min(max(0, $0.upperBound, $0.lowerBound), u.count) })
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
            if let before = out.last, r.upperBound < u.count, !isSpace(before), !isSpace(u[r.upperBound]) { out.append(0x20) }
            a = r.upperBound
        }
        out += u[a...]
        return (String(decoding: out, as: UTF16.self), removed)
    }

    /// Where a hidden node of `nodeLength` units sits in a selection of `length`, from two text-marker distances: `d1`
    /// from the selection's start to the node's start, `d2` from the node's start to the selection's end. Inside when
    /// d1 + d2 is the selection's length, starting d1 before it when d2 is d1 + length (it may overlap the start).
    /// Chromium can count a block boundary's line break on one side only, so within `tolerance` the place is kept but
    /// not `exact` (the caller then looks for the text nearby instead). `skip`: how much of the node's text lies
    /// before the selection. nil when the node is outside the selection.
    public static func place(d1: Int, d2: Int, length: Int, nodeLength: Int, tolerance: Int = 2) -> (range: Range<Int>, exact: Bool, skip: Int)? {
        guard d1 >= 0, d2 >= 0, length > 0, nodeLength > 0 else { return nil }
        let offset: Int, exact: Bool
        if d1 + d2 == length { (offset, exact) = (d1, true) }   // both exact relations before either tolerance
        else if d2 - d1 == length { (offset, exact) = (-d1, true) }
        else if abs(d1 + d2 - length) <= tolerance { (offset, exact) = (d1, false) }
        else if abs(d2 - d1 - length) <= tolerance { (offset, exact) = (-d1, false) }
        else { return nil }
        let lo = max(0, offset), hi = min(length, offset + nodeLength)
        return lo < hi ? (lo..<hi, exact, lo - offset) : nil
    }

    /// The one occurrence of `string` within `slack` units of `near`, or nil (none, or more than one). For a hidden node
    /// whose offsets did not line up exactly: never a search of the whole selection, which could cut a visible "Copy"
    /// out of "Copyright".
    public static func locate(_ string: String, in text: String, near: Range<Int>, slack: Int = 8) -> Range<Int>? {
        let ns = text as NSString, n = (string as NSString).length
        guard n > 0, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lo = max(0, near.lowerBound - slack), hi = min(ns.length, max(near.upperBound, near.lowerBound + n) + slack)
        guard hi - lo >= n else { return nil }
        var found: [Range<Int>] = []
        var from = lo
        while from + n <= hi {
            let r = ns.range(of: string, options: .literal, range: NSRange(location: from, length: hi - from))
            guard r.location != NSNotFound else { break }
            found.append(r.location..<r.location + r.length)
            from = r.location + 1
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Safety net for Claude text the tree cannot place (a Copy, or a selection without text markers; the caller decides): a screen reader heading straight
    /// before the text it repeats, "Claude responded: X" or "You said: X" followed by X (a long heading is cut short
    /// with "…", so then X's opening). The longest X that repeats wins, so "You said: I love you. I love you. Stay."
    /// before its message cuts the whole heading, not one "I love you.". Returns the headings' ranges.
    public static func repeatedHeadings(_ text: String) -> [Range<Int>] {
        let u = Array(text.utf16).map(plainQuote)   // the heading has straight quotes where the message has curly ones
        var found: [Range<Int>] = []
        for prefix in prefixes {
            let p = Array(prefix.utf16)
            var i = 0
            while i + p.count <= u.count {
                guard u[i..<i + p.count].elementsEqual(p) else { i += 1; continue }
                let a = i + p.count
                // The heading's own text runs from a to e; the message body, starting at e, opens with the same text.
                var hit: Int?
                var e = min(u.count, a + window)
                while e >= a + minimum {
                    var h = e - a
                    if u[e - 1] == 0x2026 { h -= 1 }   // "…": the heading was cut short, the body goes on
                    if h >= minimum, e + h <= u.count, u[a..<a + h].elementsEqual(u[e..<e + h]) { hit = e; break }
                    e -= 1
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

    /// Shortest heading text taken as a repeat, and the longest looked for (a heading holds one sentence, or about
    /// 150 characters and "…").
    static let minimum = 12, window = 600
}
