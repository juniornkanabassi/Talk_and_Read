// The node map's word alignment: a selection's words against the word stream of an app's Accessibility text nodes.
// Pure, so it is tested here; `Locator` (app target) owns the AX walk and the rects.

public enum NodeAlignment {
    /// Roles whose text is app chrome (buttons, pickers, tabs, toolbars, menus), never document text. Not here: links
    /// (inline links are part of the text) and containers such as AXTabGroup, which holds its tabs (AXRadioButton)
    /// and also the selected tab's page.
    public static let chromeRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle",
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem",
    ]

    /// A node is chrome when its own role is, or it sits anywhere inside a chrome element (a button's label text).
    public static func isChrome(role: String?, parentChrome: Bool) -> Bool {
        parentChrome || role.map(chromeRoles.contains) == true
    }

    /// The window's text nodes, in document order, as one lowercased word stream with each word's node and local
    /// range. A word inside chrome stays in the stream as "", which no selection word equals: it can neither anchor
    /// nor extend a run, so exposed text ending mid-sentence right before a "Copy" button can no longer step onto it,
    /// while every other word keeps the stream position it had before.
    public static func stream(_ nodes: [(value: String, chrome: Bool)]) -> [(node: Int, word: String, range: Range<Int>)] {
        nodes.enumerated().flatMap { index, node in
            TextKit.tokenize(node.value).map { (index, node.chrome ? "" : $0.text.lowercased(), $0.range) }
        }
    }

    /// Aligns `selectionWords[start...]` and returns full selection index -> stream index. Anchors on the three words
    /// at `start`, not the selection's first three: on a long read Chromium and CodeMirror expose only the text near
    /// the viewport, so by the time later words have nodes the opening words may have none.
    /// Every anchor position is a candidate (an inbox preview row can open with the same words as the message body);
    /// from the selection's start the one covering the most words wins; equally good complete matches are settled by
    /// `prefer` (stream indices inside the capture element's subtree) or, failing that, hidden (returns [:]).
    public static func best(_ streamWords: [String], _ selectionWords: [String], from start: Int = 0, prefer: Set<Int>? = nil) -> [Int: Int] {
        guard start >= 0, start < selectionWords.count else { return [:] }
        let words = Array(selectionWords[start...])
        let w = min(3, words.count)
        guard streamWords.count >= w else { return [:] }
        var best: [Int: Int] = [:]
        var candidates: [(map: [Int: Int], back: Int, run: Int)] = []
        var complete: [[Int: Int]] = []   // from start 0: every candidate that places all the words
        for p in 0...(streamWords.count - w) where (0..<w).allSatisfy({ streamWords[p + $0] == words[$0] }) {
            let candidate = alignStream(streamWords, words, startingAt: p)
            if start == 0 {
                if better(candidate, than: best) { best = candidate }
                if candidate.count == words.count { complete.append(candidate) }
                continue
            }
            var back = 0 // selection words just spoken that also sit just before this anchor in the stream
            while back < 8, p - 1 - back >= 0, start - 1 - back >= 0,
                  streamWords[p - 1 - back] == selectionWords[start - 1 - back] { back += 1 }
            var run = 0 // unbroken matches from the anchor: a resync can jump into another copy and borrow its words
            while candidate[run] == p + run { run += 1 }
            candidates.append((candidate, back, run))
        }
        if start == 0 {
            // The phrase can be on screen twice (a preview and the message, a quote). Several different complete matches
            // that are equally good (same span) are ambiguous: use the single one inside `prefer` (the capture element's
            // subtree, or the OCR words around the selection), otherwise hide rather than box the wrong copy. A tab title
            // that resyncs across a wide gap is not as good (wider span), so it is not a tie.
            if best.count == words.count {
                var ties: [[Int: Int]] = []
                for c in complete where !better(c, than: best) && !better(best, than: c) && !ties.contains(c) { ties.append(c) }
                if ties.count > 1 {
                    let inside = ties.filter { t in prefer.map { Set(t.values).isSubset(of: $0) } ?? false }
                    guard inside.count == 1 else { return [:] }
                    best = inside[0]
                }
            }
        }
        if start > 0 {
            // Mid-text a phrase can repeat (toolbar text, a heading, a preview, repeated instructions). An alignment is
            // used only with five unbroken matching words (or all there are), counting those just before the anchor,
            // and only if it has more of those preceding words, and no fewer unbroken ones, than every other such
            // alignment that puts the spoken word elsewhere; otherwise the words hide. Only the unbroken run is kept:
            // words past a resync are placed by their own rebuild when they are spoken.
            let needed = min(5, words.count + min(start, 8))
            let confident = candidates.filter { $0.run + $0.back >= needed }
            guard let winner = confident.first(where: { c in
                confident.allSatisfy { o in o.map[0] == c.map[0] || (c.back > o.back && c.run >= o.run) }
            }) else { return [:] }
            best = winner.map.filter { $0.key < winner.run }
        }
        return Dictionary(uniqueKeysWithValues: best.map { (start + $0.key, $0.value) })
    }

    /// Walks `streamWords` and `selectionWords` in parallel from `start`: a match advances both; a mismatch
    /// skips a stray stream word (up to 3 times) before giving up on that selection word too. Returns
    /// selection-index -> stream-index for every selection word it could place.
    public static func alignStream(_ streamWords: [String], _ selectionWords: [String], startingAt start: Int) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var q = start, i = 0
        while i < selectionWords.count, q < streamWords.count {
            // A chrome word ("") is never a selection word: step over it, so a stretch of it (Claude's hidden heading,
            // toolbar and timestamps between two messages, often more than 40 words) does not end the run.
            if streamWords[q].isEmpty { q += 1; continue }
            if streamWords[q] == selectionWords[i] {
                map[i] = q
                q += 1; i += 1
                continue
            }
            // Out of step (a UI word in the stream, or a token Speechify's copy lacks): resync on the next
            // three selection words anywhere in the next 40 stream words, else drop this selection word.
            let probe = Array(selectionWords[i..<min(i + 3, selectionWords.count)])
            var found: Int?
            let upper = max(q, min(q + 40, streamWords.count - probe.count + 1))
            for c in q..<upper
            where (0..<probe.count).allSatisfy({ streamWords[c + $0] == probe[$0] }) { found = c; break }
            if let c = found { q = c } else { i += 1 }
        }
        return map
    }

    /// A larger match count wins outright. On a tie, prefer the map whose matched stream indices sit closest
    /// together (smallest span): a note's tab title repeats its opening words and can align just as many
    /// selection words as the real body, but only after resyncing across a wide gap in the stream.
    public static func better(_ candidate: [Int: Int], than best: [Int: Int]) -> Bool {
        if candidate.count != best.count { return candidate.count > best.count }
        return span(candidate) < span(best)
    }

    static func span(_ map: [Int: Int]) -> Int {
        guard let lo = map.values.min(), let hi = map.values.max() else { return 0 }
        return hi - lo
    }
}
