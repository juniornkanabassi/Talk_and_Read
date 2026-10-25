// Word range -> screen rectangle (ported from ReadAlong 1.0.5). Paths in order: direct AXBoundsForRange on the capture
// element, the AX node map (Chromium, Electron, WebKit), PDF (PDFKit + AXPage), OCR (Vision, only with Screen Recording).
// Hides rather than guesses: a missing rectangle is a valid, expected result.
import AppKit
import ApplicationServices
import TalkReadCore

@MainActor final class Locator {
    enum Path: String { case direct, nodeMap, pdf, ocr, none }

    let capture: Capture
    private(set) var pathUsed: Path = .direct
    /// What the last node map build saw, for logs and the self-test.
    private(set) var nodeMapSummary = "not built"
    /// Selection words the node map has placed on a node, for the self-test.
    var nodeMapCount: Int { nodeMap?.count ?? 0 }
    private let tokens: [Token]
    private let useOCR: Bool

    // Switch to "none" after three consecutive different ranges find nothing and no path has anything to offer.
    private var failedRange: Range<Int>?
    private var consecutiveFailures = 0
    private var noneSince: TimeInterval = 0

    // Node map: built lazily from capture.window, then extended from any word it lacks, at most once a second.
    // Chromium/Electron apps put the selection on a whole-document AXGroup/AXWebArea that doesn't answer
    // AXBoundsForRange, but its AXStaticText descendants do, for ranges local to their own AXValue.
    private var nodeMap: [Int: (node: AXUIElement, range: CFRange)]?
    private var nodeMapBuiltAt: TimeInterval = 0
    private var pdfLocator: PDFLocator??      // .some(nil): tried, not a PDF window
    private var ocrLocator: OCRLocator??      // .some(nil): no window to capture
    /// Set by the shared bounds lookup when the word has bounds but sits outside its scroll area or window: hidden, not a
    /// failure of the path (a sentence half off screen must never latch the locator to "none").
    private var hiddenByClip = false

    init(capture: Capture, useOCR: Bool = false) {
        self.capture = capture
        self.tokens = TextKit.tokenize(capture.text)
        self.useOCR = useOCR
    }

    /// `range` is UTF-16 offsets into `capture.text`. Returns Cocoa screen coordinates, or nil (never a guess).
    func rect(forWord range: Range<Int>) -> CGRect? {
        hiddenByClip = false
        let now = Date().timeIntervalSince1970
        if pathUsed == .none, now - noneSince > 1 {
            // "none" is a rest, not a verdict: Chromium replaces nodes after a scroll or re-layout, so a fresh map is
            // tried once a second for as long as the session lasts.
            (pathUsed, consecutiveFailures, failedRange, nodeMap) = (.direct, 0, nil, nil)
        }
        guard pathUsed != .none, let index = tokenIndex(for: range) else { return nil }
        // OCR only wins once every AX path came up empty for this window; stay on it instead of re-asking AX each tick.
        if pathUsed == .ocr, let ocr = ocrLocator ?? nil {
            if let rect = ocr.rect(forTokenIndex: index) { return succeed(.ocr, rect) }
            return ocr.isPending ? nil : fail(range)
        }
        if let rect = rectViaDirect(range) { return succeed(.direct, rect) }
        if hiddenByClip { return nil }
        switch rectViaNodeMap(index) {
        case .rect(let rect): return succeed(.nodeMap, rect)
        case .hidden: return nil
        case .stale, .noEntry: break
        }
        if let rect = rectViaPDF(index) { return succeed(.pdf, rect) }
        if (nodeMap ?? [:]).isEmpty, (pdfLocator ?? nil)?.isEmpty ?? true, let ocr = ocr() {   // no AX geometry at all
            if let rect = ocr.rect(forTokenIndex: index) { return succeed(.ocr, rect) }
            if ocr.isPending { return nil }   // first recognition still running: not a failure
        }
        return fail(range)
    }

    /// The same lookup for the sentence tint. A miss here says nothing about the path (a sentence half off screen, or past
    /// the node map's alignment, must not switch the word box off), so every failure counter is restored.
    func tintRect(forWord range: Range<Int>) -> CGRect? {
        let saved = (consecutiveFailures, failedRange, pathUsed)
        defer {
            (consecutiveFailures, failedRange) = (saved.0, saved.1)
            if pathUsed == .none { pathUsed = saved.2 }
        }
        return rect(forWord: range)
    }

    var ocrSummary: String { (ocrLocator ?? nil)?.summary ?? "not used" }

    /// After a scroll, resize or window move. The node map stays (scrolling doesn't change nodes); OCR re-captures.
    func invalidate() {
        clipCache = nil
        (ocrLocator ?? nil)?.invalidate()
    }

    /// The window moved or was resized: the clip is stale, OCR boxes are window-relative and stay.
    func windowChanged() { clipCache = nil }

    private func succeed(_ path: Path, _ rect: CGRect) -> CGRect {
        (pathUsed, consecutiveFailures, failedRange) = (path, 0, nil)
        return rect
    }

    private func fail(_ range: Range<Int>) -> CGRect? {
        if failedRange != range {
            consecutiveFailures += 1
            failedRange = range
        }
        if consecutiveFailures >= 3, (nodeMap ?? [:]).isEmpty {
            pathUsed = .none   // no geometry at all from this app; a partial node map keeps serving the words it has
            noneSince = Date().timeIntervalSince1970
        }
        return nil
    }

    // MARK: - Direct

    private func rectViaDirect(_ range: Range<Int>) -> CGRect? {
        guard let element = capture.element, let start = capture.selectionStart else { return nil }
        return rect(fromBoundsOf: element, range: CFRange(location: start + range.lowerBound, length: range.count), clipFrom: element)
    }

    // MARK: - Node map

    private enum NodeMapResult { case rect(CGRect), noEntry, stale, hidden }

    private func rectViaNodeMap(_ index: Int) -> NodeMapResult {
        if nodeMap == nil { buildNodeMap(from: index) }
        let result = nodeMapLookup(index)
        switch result { case .rect, .hidden: return result; case .stale, .noEntry: break }
        // A long read outruns the map built at its start: Chromium and CodeMirror expose only the text near the viewport,
        // and a scroll can replace the nodes already mapped. Re-walk from this word, at most once a second.
        guard !(nodeMap ?? [:]).isEmpty, Date().timeIntervalSince1970 - nodeMapBuiltAt > 1 else { return result }
        buildNodeMap(from: index)
        return nodeMapLookup(index)
    }

    private func nodeMapLookup(_ index: Int) -> NodeMapResult {
        guard let entry = nodeMap?[index] else { return .noEntry }
        if let rect = rect(fromBoundsOf: entry.node, range: entry.range, clipFrom: entry.node) { return .rect(rect) }
        return hiddenByClip ? .hidden : .stale
    }

    /// Depth-first walk of `capture.window` (document order) collecting AXStaticText/AXTextArea/AXTextField values,
    /// tokenised into one word stream and aligned against the selection's tokens from word `start`. Entries the new
    /// alignment does not place are kept. Text under a chrome role never stands in for a selection word.
    // ponytail: a full window walk per rebuild (Claude's window: 417 nodes, 24 ms; web nodes cost one more AX call for
    // their visibility), at most once a second while the spoken word has no live node; walk only the subtree around
    // the last mapped node if a big window makes this slow.
    private func buildNodeMap(from start: Int) {
        var map = nodeMap ?? [:]
        defer { nodeMap = map; nodeMapBuiltAt = Date().timeIntervalSince1970 }
        guard let window = capture.window, !tokens.isEmpty else { return }

        var nodes: [(element: AXUIElement, value: String, chrome: Bool, inside: Bool)] = []
        var webAreas: [AXUIElement] = []
        // Inside a web area, text that is never drawn (HiddenText.Visibility: Claude's screen reader headings, a hover
        // toolbar's timestamps) counts as chrome too, so the visible copy of a sentence is the one boxed.
        var stack: [(element: AXUIElement, chrome: Bool, inside: Bool, web: HiddenText.Visibility?)] = [(window, false, false, nil)]
        var visited = 0
        while let (node, parentChrome, parentInside, parentWeb) = stack.popLast(), visited < 8000 {
            visited += 1
            let children = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement]
            let role = axAttribute(node, kAXRoleAttribute) as? String
            let web = role == "AXWebArea" ? HiddenText.Visibility(chat: TextCapture.isClaudeChat(node, pid: capture.pid)) : parentWeb.map {
                $0.child(role: role, classes: (axAttribute(node, "AXDOMClassList") as? [String]) ?? [])
            }
            let value = role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" ? axAttribute(node, kAXValueAttribute) as? String : nil
            let chrome = NodeAlignment.isChrome(role: role, parentChrome: parentChrome) || web.map { !$0.draws(value ?? "") && ($0.hidden || value != nil) } == true
            let inside = parentInside || capture.element.map { CFEqual($0, node) } == true
            var descend = true
            if role == "AXWebArea" { webAreas.append(node) }
            if let role, role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField",
               let value = axAttribute(node, kAXValueAttribute) as? String, !value.isEmpty {
                if role != "AXStaticText", let children, !children.isEmpty {
                    // Obsidian's whole-document AXTextArea answers AXBoundsForRange with 0x0 for every range while its
                    // per-paragraph AXStaticText children answer for real: use the container only if it backs up its text.
                    if answersBounds(node) {
                        nodes.append((node, value, chrome, inside))
                        descend = false
                    }
                } else {
                    nodes.append((node, value, chrome, inside))
                }
            }
            if descend, let children { stack.append(contentsOf: children.reversed().map { ($0, chrome, inside, web) }) }
        }

        let stream = NodeAlignment.stream(nodes.map { ($0.value, $0.chrome) })
        guard !stream.isEmpty else { return }
        let prefer = start == 0 ? preferredStream(stream, nodes: nodes.map { ($0.element, $0.inside) }, webAreas: webAreas) : nil
        let aligned = NodeAlignment.best(stream.map(\.word), tokens.map { $0.text.lowercased() }, from: start, prefer: prefer)
        nodeMapSummary = "from \(start): \(nodes.count) nodes, \(stream.count) words, prefer \(prefer.map { String($0.count) } ?? "nil"), placed \(aligned.count)"
        for (i, q) in aligned {
            let range = stream[q].range
            map[i] = (nodes[stream[q].node].element, CFRange(location: range.lowerBound, length: range.count))
        }
    }

    /// Stream words that belong to the selection's own copy (PLAN decision 13): the capture element's words inside the
    /// selected range when the element is itself a text node; else the words drawn inside the selection's bounds
    /// (AXBoundsForRange on the element, or WebKit's selected text marker range); else every word under the element.
    private func preferredStream(_ stream: [(node: Int, word: String, range: Range<Int>)], nodes: [(element: AXUIElement, inside: Bool)],
                                 webAreas: [AXUIElement]) -> Set<Int>? {
        let length = capture.text.utf16.count
        if let element = capture.element, let start = capture.selectionStart,
           let own = nodes.firstIndex(where: { CFEqual($0.element, element) }) {
            return Set(stream.indices.filter { stream[$0].node == own && stream[$0].range.lowerBound >= start && stream[$0].range.upperBound <= start + length })
        }
        if let selection = selectionBounds(webAreas: webAreas) {
            var frames: [Int: CGRect?] = [:]
            return Set(stream.indices.filter { q in
                let node = stream[q].node
                if frames[node] == nil { frames[node] = .some(axFrame(nodes[node].element)) }
                guard let frame = frames[node] ?? nil, frame.intersects(selection) else { return false }
                if selection.insetBy(dx: -2, dy: -2).contains(frame) { return true }
                let r = stream[q].range
                guard let word = axBounds(nodes[node].element, location: r.lowerBound, length: r.count) else { return false }
                return selection.insetBy(dx: -2, dy: -2).contains(CGPoint(x: word.midX, y: word.midY))
            })
        }
        guard capture.element != nil else { return nil }
        let inside = Set(nodes.indices.filter { nodes[$0].inside })
        return inside.isEmpty ? nil : Set(stream.indices.filter { inside.contains(stream[$0].node) })
    }

    /// The selection's bounding box in AX (top-left) coordinates, read once: AXBoundsForRange on the element when its
    /// range is known; else the selected text marker range (WebKit, Chromium) of the element or, when the window is not
    /// key and nothing has focus, of the web area whose selection is the captured text.
    private var selectionBoundsValue: CGRect?? = nil
    private func selectionBounds(webAreas: [AXUIElement]) -> CGRect? {
        if let cached = selectionBoundsValue { return cached }
        var result: CGRect?
        if let element = capture.element, let start = capture.selectionStart {
            result = axBounds(element, location: start, length: capture.text.utf16.count)
        } else {
            let wanted = (capture.selected ?? capture.text).trimmingCharacters(in: .whitespacesAndNewlines)   // as selected, before any cut
            for area in (capture.element.map { [$0] } ?? []) + webAreas {
                guard let marker = axAttribute(area, "AXSelectedTextMarkerRange"),
                      (axParameterizedAttribute(area, "AXStringForTextMarkerRange", parameter: marker) as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
                      let value = axParameterizedAttribute(area, "AXBoundsForTextMarkerRange", parameter: marker),
                      CFGetTypeID(value) == AXValueGetTypeID() else { continue }
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty { result = rect; break }
            }
        }
        selectionBoundsValue = .some(result)
        return result
    }

    // MARK: - PDF and OCR

    private func rectViaPDF(_ index: Int) -> CGRect? {
        if pdfLocator == nil {
            pdfLocator = .some(capture.window.flatMap {
                PDFLocator(window: $0, tokens: tokens, anchor: PDFLocator.anchor(element: capture.element, selectionStart: capture.selectionStart))
            })
        }
        return (pdfLocator ?? nil)?.rect(forTokenIndex: index)
    }

    /// Only with the setting on and Screen Recording granted; asks for the permission at most once per launch.
    private func ocr() -> OCRLocator? {
        guard useOCR else { return nil }
        if let existing = ocrLocator { return existing }
        guard OCRLocator.hasAccess(requestOnce: true) else { return nil }
        ocrLocator = .some(OCRLocator(capture: capture, tokens: tokens))
        return ocrLocator ?? nil
    }

    // MARK: - Shared AX bounds lookup

    /// True if `element` answers `AXBoundsForRange` for its own first character with a real (non-empty) rect.
    private func answersBounds(_ element: AXUIElement) -> Bool {
        axBounds(element, location: 0, length: 1).map { !$0.isEmpty } ?? false
    }

    private func rect(fromBoundsOf element: AXUIElement, range: CFRange, clipFrom clipNode: AXUIElement) -> CGRect? {
        guard let screenRect = axBounds(element, location: range.location, length: range.length) else { return nil }
        let cocoaRect = Locator.convert(topLeftScreenRect: screenRect)
        guard Locator.isAcceptable(cocoaRect) else { return nil }
        // Text scrolled out of view still reports bounds, so a word must sit inside its scroll area (or window) to be drawn.
        if let clip = visibleClip(from: clipNode), !clip.contains(CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)) {
            hiddenByClip = true
            return nil
        }
        return cocoaRect
    }

    private var clipCache: (element: AXUIElement, rect: CGRect?, at: TimeInterval)?
    /// The resolved (scroll area or window) element for the last start element, so the parent walk only reruns on change.
    private var clipChainCache: (start: AXUIElement, target: AXUIElement?)?

    /// The enclosing AXScrollArea's frame (within six parents), else the window's, in Cocoa coordinates. Cached for
    /// `clipLife` or until a scroll, activation or window change (`invalidate`, `windowChanged`): its AXPosition and AXSize
    /// were two of the four AX round trips of every 30 Hz tick (efficiency fix 3).
    private func visibleClip(from element: AXUIElement) -> CGRect? {
        let now = Date().timeIntervalSince1970
        if let c = clipCache, now - c.at < Self.clipLife, CFEqual(c.element, element) { return c.rect }
        func walk() -> AXUIElement? {
            var e = element
            for _ in 0..<6 {
                guard let parent = axElement(e, kAXParentAttribute) else { break }
                if (axAttribute(parent, kAXRoleAttribute) as? String) == "AXScrollArea" { return parent }
                e = parent
            }
            return axElement(element, kAXWindowAttribute)
        }
        var target: AXUIElement?
        var fromCache = false
        if let cached = clipChainCache, CFEqual(cached.start, element) {
            target = cached.target
            fromCache = true
        } else {
            target = walk()
            clipChainCache = (element, target)
        }
        var clip = target.flatMap(axFrame).map(Locator.convert(topLeftScreenRect:))
        if clip == nil, fromCache {
            // The cached target can be an element the app has since destroyed (virtualised lists replace scroll areas too).
            target = walk()
            clipChainCache = (element, target)
            clip = target.flatMap(axFrame).map(Locator.convert(topLeftScreenRect:))
        }
        clipCache = (element, clip, now)
        return clip
    }

    nonisolated static let clipLife = 0.25

    static func isAcceptable(_ rect: CGRect) -> Bool {
        if rect.isEmpty || rect.width > 2000 || rect.height > 300 { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.contains { $0.frame.contains(center) }
    }

    /// AX and CGWindow rects have their origin at the top left of the primary display; Cocoa at the bottom left.
    /// This reflection is its own inverse (checked by the self-test).
    nonisolated static func convert(topLeftScreenRect rect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0 // empty for a moment while displays reconfigure
        return CGRect(x: rect.origin.x, y: primaryScreenHeight - (rect.origin.y + rect.height), width: rect.width, height: rect.height)
    }

    private func tokenIndex(for range: Range<Int>) -> Int? {
        var low = tokens.startIndex, high = tokens.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if tokens[mid].range.lowerBound < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        return low < tokens.endIndex && tokens[low].range == range ? low : nil
    }
}
