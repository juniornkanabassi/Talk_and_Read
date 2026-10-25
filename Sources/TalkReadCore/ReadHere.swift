// Read from here (1.0): the pure parts of reading the paragraph under the pointer with no selection. The reveal key's
// state machine (the play glyph shows while the key is held on its own), the start of a paragraph in plain text, and the
// text of a page's nodes joined for reading when the app cannot hand over the range in one piece.
import Foundation

public enum RevealEvent: Equatable, Sendable {
    case keyDown, keyUp
    /// Any other key or modifier going down while the reveal key may be held.
    case otherKey
}

public enum RevealAction: Equatable, Sendable { case show, hide }

/// Shows the play glyph once the reveal key has been down alone for `delay`, and hides it when the key goes up or another
/// key joins it. A key that joins before the delay (⌥D, ⌥←) shows nothing until the key is pressed again.
public struct RevealState: Equatable, Sendable {
    public static let delay = 0.35

    enum Hold: Equatable { case up, pending(since: Double), shown, chorded }
    private(set) var hold: Hold = .up

    public init() {}

    public var isShown: Bool { hold == .shown }

    public mutating func handle(_ e: RevealEvent, at time: Double) -> [RevealAction] {
        switch e {
        case .keyDown:
            // A second key-down means the key-up was missed: start again.
            let wasShown = hold == .shown
            hold = .pending(since: time)
            return wasShown ? [.hide] : []
        case .keyUp:
            defer { hold = .up }
            return hold == .shown ? [.hide] : []
        case .otherKey:
            switch hold {
            case .pending: hold = .chorded; return []
            case .shown: hold = .chorded; return [.hide]
            case .up, .chorded: return []
            }
        }
    }

    public mutating func tick(at time: Double) -> [RevealAction] {
        guard case .pending(let since) = hold, time - since >= Self.delay else { return [] }
        hold = .shown
        return [.show]
    }

    /// Forgets the key (hotkeys paused, settings reloaded); hides a glyph on show.
    public mutating func reset() -> [RevealAction] {
        defer { hold = .up }
        return hold == .shown ? [.hide] : []
    }
}

public enum ReadHere {
    /// The UTF-16 offset where the paragraph holding `index` starts in `text`: just after the last line break before it.
    public static func paragraphStart(_ text: String, at index: Int) -> Int {
        let ns = text as NSString
        let i = min(max(0, index), ns.length)
        let breaks = CharacterSet.newlines
        var start = i
        while start > 0 {
            if let scalar = UnicodeScalar(ns.character(at: start - 1)), breaks.contains(scalar) { break }   // a surrogate half is never a break
            start -= 1
        }
        return start
    }

    /// The text of a page's text nodes in reading order, for an app that cannot give one range from a paragraph to the
    /// end. Nodes on the same line or the next one are joined with a space; a gap below the last node of more than 0.4 of a
    /// line (a new paragraph, heading or list item) becomes a blank line, so sentences and paragraphs read as they are
    /// drawn. A line is the shorter of the two nodes' heights, 8 to 40 pt, since a wrapped node spans several lines.
    /// Two nodes touching on one line with no space at their edges are one word split by styling
    /// ("inter<b>national</b>", "word" "."), joined with nothing between them.
    /// `top`, `bottom`, `left` and `right` are each node's frame edges in top-left coordinates, nil when unknown.
    public static func join(_ nodes: [(text: String, top: Double?, bottom: Double?, left: Double?, right: Double?)]) -> String {
        var out = ""
        var last: (top: Double, bottom: Double)?, lastRight: Double?, lastSpaced = true
        for node in nodes {
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let frame = node.top.flatMap { top in node.bottom.map { (top: top, bottom: max(top, $0)) } }
            if !out.isEmpty {
                var gap = false, touching = false
                if let frame, let last {
                    let line = min(40, max(8, min(frame.bottom - frame.top, last.bottom - last.top)))
                    gap = frame.top - last.bottom > 0.4 * line
                    let sameLine = frame.top < last.bottom - 0.5 * line && last.top < frame.bottom - 0.5 * line
                    if sameLine, let left = node.left, let lastRight { touching = abs(left - lastRight) < 1.5 }
                }
                let spaced = lastSpaced || node.text.first?.isWhitespace == true
                out += gap ? "\n\n" : touching && !spaced ? "" : " "
            }
            out += text
            if let frame { last = frame }
            lastRight = node.right
            lastSpaced = node.text.last?.isWhitespace == true
        }
        return out
    }
}
