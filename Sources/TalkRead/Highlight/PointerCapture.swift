// Read from here (1.0): what to read when there is no selection, only a pointer. The system-wide hit test finds the
// element under it; the nearest paragraph-sized element above that (a paragraph, heading, list item or table cell) is
// where the read starts and where the play glyph sits. A web area (Chromium, Electron, WebKit) hands over the text from
// that paragraph to the end of the page as one text-marker range, which also lets the hidden-text cut place Claude's
// screen reader headings; without markers its text nodes are joined in order. A native text view gives its value from
// the paragraph's first character. The capture then goes to the same Locator and Highlighter as a selection.
import AppKit
import ApplicationServices
import TalkReadCore

enum PointerCapture {
    /// The paragraph under a point, as the glyph and the read need it.
    struct Block {
        let pid: pid_t
        /// The paragraph-sized element (web), or the text view itself (native).
        let element: AXUIElement
        /// The paragraph's frame in AX (top-left) coordinates: the glyph sits beside its first line.
        let frame: CGRect
        /// Native text: the paragraph's first character within the element's value, and the paragraph's length.
        let start: Int?
        var length = 0
    }

    private static let maxText = 200_000
    /// Roles that are only part of a line: the climb goes past them to the paragraph that holds them.
    private static let inline: Set<String> = ["AXStaticText", "AXLink", "AXImage", "AXButton", "AXMark", "AXTextMarker"]
    private static let nativeText: Set<String> = ["AXTextArea", "AXTextField"]

    /// The element under `point` (AX top-left coordinates) and its app; nil over our own windows or nothing.
    @MainActor static func hit(_ point: CGPoint) -> (element: AXUIElement, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)   // a hung app costs one tenth of a second, not six, for this call only
        var found: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        AXUIElementSetMessagingTimeout(system, 0)   // the system-wide timeout is every element's: put the default back
        guard result == .success, let found else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(found, &pid) == .success, pid != getpid() else { return nil }
        return (found, pid)
    }

    /// The paragraph under `point`. `wake` first wakes the app's tree (Chromium and Electron build it on request), so a
    /// first hit on a sleeping Claude window that finds only the window finds the text on the second try.
    /// `inUse` names an app a newer read is using by the time the lookup gives up, whose wake must stay.
    @MainActor static func block(at point: CGPoint, wake: Bool, inUse: () -> pid_t? = { nil }) async -> Block? {
        guard let first = hit(point) else { return nil }
        if let b = block(from: first.element, pid: first.pid, point: point) { return b }
        guard wake else { return nil }
        await AXWake.wake(AXUIElementCreateApplication(first.pid), pid: first.pid)
        // A cold Electron tree (Codex, Claude) fills in over the next half second or so: try a few times.
        for attempt in 0..<5 {
            if let again = hit(point), again.pid == first.pid, let b = block(from: again.element, pid: again.pid, point: point) { return b }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        if inUse() != first.pid { AXWake.restore(first.pid) }   // nothing to read there: no Highlighter will put the app back
        return nil
    }

    @MainActor static func block(from element: AXUIElement, pid: pid_t, point: CGPoint) -> Block? {
        let role = axAttribute(element, kAXRoleAttribute) as? String ?? ""
        if TextCapture.isSecure(element) { return nil }   // never read a password field, natively or as part of a page
        // A text view, or a web page's editable text when it answers like one; a contenteditable that does not falls
        // through to the web path below.
        if nativeText.contains(role), !TextCapture.isXterm(element), let b = nativeBlock(element, pid: pid, point: point) { return b }
        guard let area = TextCapture.webArea(of: element), (axAttribute(area, kAXRoleAttribute) as? String) == "AXWebArea",
              let areaFrame = axFrame(area) else { return nil }
        // Chromium's hit test can stop at a list of messages: go down to the deepest element under the point first,
        // then climb past the inline parts (and groups on a line beside their parent's text) to the first element that is
        // a block of its own, stopping below the web area.
        var current = deepest(element, at: point), steps = 0
        while steps < 12, !CFEqual(current, area), let parent = axElement(current, kAXParentAttribute),
              inline.contains(axAttribute(current, kAXRoleAttribute) as? String ?? "") || sharesLine(current, in: parent) {
            current = parent
            steps += 1
        }
        // The page itself, or a container most of a screen tall, is no paragraph: the pointer is in a margin or a gap.
        guard !CFEqual(current, area), let frame = axFrame(current), !frame.isEmpty,
              frame.height < max(240, areaFrame.height * 0.6) || onlyText(current), frame.insetBy(dx: -4, dy: -4).contains(point),
              !isContainer(current, frame: frame), hasText(current, area: area) else { return nil }
        return Block(pid: pid, element: current, frame: frame, start: nil)
    }

    /// The deepest descendant of `element` (itself when none) whose frame holds the point; ten levels, 200 children each.
    private static func deepest(_ element: AXUIElement, at point: CGPoint) -> AXUIElement {
        var current = element
        for _ in 0..<10 {
            if inline.contains(axAttribute(current, kAXRoleAttribute) as? String ?? "") { break }   // the climb starts here
            let children = (axAttribute(current, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            guard let next = children.prefix(200).first(where: { axFrame($0).map { !$0.isEmpty && $0.insetBy(dx: -1, dy: -1).contains(point) } ?? false })
            else { break }
            current = next
        }
        return current
    }

    /// Where a read from `block` ends: the end of its column, the highest ancestor below the web area no wider than about
    /// the paragraph. A chat beside a thread pane or a browser pane (Claude, Codex), or an article beside a sidebar,
    /// then stops at the end of its own column instead of reading on into the next one. A short heading or list item is
    /// narrower than its column, so an ancestor up to three quarters of the page's width still counts as the column.
    private static func column(of element: AXUIElement, frame: CGRect, area: AXUIElement) -> AXUIElement {
        let limit = max(frame.width * 1.6 + 60, (axFrame(area)?.width ?? 0) * 0.75)
        var best = element, current = element
        for _ in 0..<40 {
            guard let parent = axElement(current, kAXParentAttribute), !CFEqual(parent, area) else { break }
            current = parent
            guard let f = axFrame(current), !f.isEmpty else { continue }   // an ignored wrapper: look above it
            if f.width > limit || hasSideBySide(current, beside: best) { break }
            best = current
        }
        return best
    }

    /// A child of `parent` beside `column` rather than above or below it (a sidebar, a second pane): the parent holds
    /// more than one column.
    private static func hasSideBySide(_ parent: AXUIElement, beside column: AXUIElement) -> Bool {
        guard let c = axFrame(column) else { return false }
        return ((axAttribute(parent, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(40).contains { child in
            // A real column, not a list bullet or an avatar beside its text.
            guard let f = axFrame(child), f.width >= max(60, c.width * 0.2), f.height >= 1, !f.contains(c) else { return false }
            return (f.maxX <= c.minX + 1 || f.minX >= c.maxX - 1) && f.minY < c.maxY && c.minY < f.maxY
        }
    }

    /// Nothing but text runs inside: a paragraph however tall, never a container of blocks.
    private static func onlyText(_ element: AXUIElement) -> Bool {
        let children = (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return !children.isEmpty && children.prefix(200).allSatisfy { inline.contains(axAttribute($0, kAXRoleAttribute) as? String ?? "") }
    }

    /// A generic group on one line beside its parent's own text (a chip, a code span, a styled run) is part of that
    /// paragraph, not a block of its own.
    private static func sharesLine(_ element: AXUIElement, in parent: AXUIElement) -> Bool {
        guard let f = axFrame(element), f.height < 60 else { return false }
        return ((axAttribute(parent, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(40).contains { s in
            guard !CFEqual(s, element), inline.contains(axAttribute(s, kAXRoleAttribute) as? String ?? ""), let o = axFrame(s) else { return false }
            return o.minY < f.maxY - 1 && f.minY < o.maxY - 1
        }
    }

    /// A message or a section rather than a paragraph: two of its children are wide blocks stacked one above the other
    /// (the pointer is in a gap between paragraphs). Inline code and links are narrow, so a paragraph holding them is not.
    private static func isContainer(_ element: AXUIElement, frame: CGRect) -> Bool {
        let children = (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var blocks: [CGRect] = []
        for child in children.prefix(40) where !inline.contains(axAttribute(child, kAXRoleAttribute) as? String ?? "") {
            guard let f = axFrame(child), f.height >= 1, f.width >= frame.width * 0.5 else { continue }
            if blocks.contains(where: { f.minY >= $0.maxY - 1 || $0.minY >= f.maxY - 1 }) { return true }
            blocks.append(f)
        }
        return false
    }

    /// A native text view: the paragraph holding the character under the point.
    private static func nativeBlock(_ element: AXUIElement, pid: pid_t, point: CGPoint) -> Block? {
        var p = point
        guard let parameter = AXValueCreate(.cgPoint, &p),
              let value = axParameterizedAttribute(element, "AXRangeForPosition", parameter: parameter), CFGetTypeID(value) == AXValueGetTypeID(),
              let text = axAttribute(element, kAXValueAttribute) as? String else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location != kCFNotFound, range.location < (text as NSString).length else { return nil }
        let start = ReadHere.paragraphStart(text, at: range.location)
        let ns = text as NSString
        var end = ns.rangeOfCharacter(from: .newlines, range: NSRange(location: start, length: ns.length - start)).location
        if end == NSNotFound { end = ns.length }
        guard end > start, !ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let frame = axBounds(element, location: start, length: end - start), !frame.isEmpty,
              frame.contains(point) else { return nil }   // the nearest character to a margin or a gap is not under it
        return Block(pid: pid, element: element, frame: frame, start: start, length: end - start)
    }

    private static func hasText(_ element: AXUIElement, area: AXUIElement) -> Bool {
        if let range = markerRange(of: element, in: area),
           let s = axParameterizedAttribute(area, "AXStringForTextMarkerRange", parameter: range) as? String {
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !textNodes(under: element, limit: 50).isEmpty
    }

    // MARK: - The read

    /// The text from the block to the end of its page or document, ready for `AppModel.startSession`.
    @MainActor static func capture(_ block: Block) -> Capture? {
        let window = window(of: block.element)
        if let start = block.start {   // native text: the direct path boxes each word from the paragraph's offset
            guard let text = axAttribute(block.element, kAXValueAttribute) as? String else { return nil }
            let ns = text as NSString
            guard start < ns.length else { return nil }
            let wanted = NSRange(location: start, length: min(ns.length - start, maxText))
            let tail = ns.substring(with: ns.rangeOfComposedCharacterSequences(for: wanted))
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Capture(text: tail, pid: block.pid, element: block.element, window: window, selectionStart: start, source: .pointer)
        }
        guard let area = TextCapture.webArea(of: block.element) else { return nil }
        // A paragraph straight under the page (plain HTML) has no column of its own: the page is the column.
        let parent = axElement(block.element, kAXParentAttribute)
        let end = parent.map { CFEqual($0, area) } == true ? area : column(of: block.element, frame: block.frame, area: area)
        if let own = markerRange(of: block.element, in: area), let page = markerRange(of: end, in: area),
           let range = axParameterizedAttribute(area, "AXTextMarkerRangeForUnorderedTextMarkers",
                                                parameter: [AXTextMarkerRangeCopyStartMarker(own), AXTextMarkerRangeCopyEndMarker(page)] as CFArray),
           CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
           let text = axParameterizedAttribute(area, "AXStringForTextMarkerRange", parameter: range) as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The element is the paragraph, so the node map prefers its own words for the start of the read.
            let c = Capture(text: text, pid: block.pid, element: block.element, window: window, selectionStart: nil, source: .pointer)
            if text.utf16.count > maxText {   // too long to place hidden nodes in one walk: the first part, through the text-only net
                let ns = text as NSString
                let head = ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: maxText)))
                return TextCapture.withoutHiddenText(Capture(text: head, pid: block.pid, element: block.element, window: window, selectionStart: nil, source: .pointer),
                                                     root: area, selection: nil)
            }
            return TextCapture.withoutHiddenText(c, root: area, selection: (range as! AXTextMarkerRange))
        }
        // No text markers: the page's text nodes from the block on, in document order.
        let nodes = textNodes(under: end, from: block.element, limit: 6000)
        let text = ReadHere.join(nodes.map { node in
            let f = axFrame(node.element)
            return (node.text, f.map { Double($0.minY) }, f.map { Double($0.maxY) })
        })
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ns = text as NSString
        let clipped = ns.length > maxText ? ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: maxText))) : text
        // No markers to place hidden nodes with: in Claude's chat the text-only net still drops its headings.
        return TextCapture.withoutHiddenText(Capture(text: clipped, pid: block.pid, element: block.element, window: window, selectionStart: nil, source: .pointer),
                                             root: area, selection: nil)
    }

    /// The element's own text-marker range in its web area, when the app answers with one.
    private static func markerRange(of element: AXUIElement, in area: AXUIElement) -> AXTextMarkerRange? {
        guard let range = axParameterizedAttribute(area, "AXTextMarkerRangeForUIElement", parameter: element),
              CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (range as! AXTextMarkerRange)
    }

    /// AXStaticText values below `root` in document order; with `from`, only those at or after that element (itself and
    /// what it holds included). Text under a chrome role (a toolbar, a menu) never counts.
    private static func textNodes(under root: AXUIElement, from: AXUIElement? = nil, limit: Int) -> [(element: AXUIElement, text: String)] {
        var out: [(AXUIElement, String)] = []
        var started = from == nil
        var stack: [(element: AXUIElement, chrome: Bool)] = [(root, false)]
        var visited = 0
        // ponytail: a whole-page walk on the main thread, only for apps without text markers; bounded by count and time.
        let deadline = ContinuousClock.now + .milliseconds(300)
        while let (node, parentChrome) = stack.popLast(), visited < limit {
            visited += 1
            if visited % 64 == 0, ContinuousClock.now > deadline { break }
            if !started, let from, CFEqual(node, from) { started = true }
            let role = axAttribute(node, kAXRoleAttribute) as? String
            let chrome = NodeAlignment.isChrome(role: role, parentChrome: parentChrome)
            if started, !chrome, role == "AXStaticText", let value = axAttribute(node, kAXValueAttribute) as? String, !value.isEmpty {
                out.append((node, value))
                continue   // a text node is a leaf whatever Chromium hangs below it (inline text boxes)
            }
            if let children = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, chrome) })
            }
        }
        return out
    }

    /// The window holding `element`: its AXWindow, else the nearest ancestor with the window role.
    private static func window(of element: AXUIElement) -> AXUIElement? {
        if let w = axElement(element, kAXWindowAttribute) { return w }
        var current: AXUIElement? = element
        for _ in 0..<60 {
            guard let e = current else { break }
            if (axAttribute(e, kAXRoleAttribute) as? String) == kAXWindowRole { return e }
            current = axElement(e, kAXParentAttribute)
        }
        return nil
    }
}
