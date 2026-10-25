// What to read when the user presses Read (PLAN decision 6): AX selection → Edit ▸ Copy inside the PasteboardGate
// (pressed through AX only; no synthetic ⌘C, Sol #22) → caret to end of the focused text → the existing clipboard
// → nil. AX part ported from ReadAlong.
import AppKit
import ApplicationServices
import TalkReadCore

struct Capture {
    enum Source { case accessibility, copied, cursor, clipboard, ocr, provided }
    let text: String
    let pid: pid_t
    /// The element the selection lives in (copied: the focused element), when known.
    let element: AXUIElement?
    /// The window `element` lives in; the node map, PDF and OCR locators walk or capture it.
    let window: AXUIElement?
    /// UTF-16 offset of `text` within `element`'s value, when known exactly.
    let selectionStart: Int?
    let source: Source
    /// UTF-16 units of hidden text (a screen reader heading, a hover toolbar) cut from the selection, for the log.
    var hiddenRemoved = 0
    /// The selection's own text when hidden text was cut from it: the Locator still recognises the live selection by it.
    var selected: String?

    /// Sources whose text has a place on screen; the Highlighter draws only for these. Clipboard text only with a window
    /// (an xterm terminal's own ⌘C, see `TextCapture.read`).
    var hasGeometry: Bool { [.accessibility, .copied, .cursor, .ocr].contains(source) || source == .clipboard && window != nil }
}

enum TextCapture {
    /// The gate the copy and clipboard steps use; the self-test swaps in a private pasteboard.
    static var gate = PasteboardGate.shared
    private static let maxCaretText = 200_000

    @MainActor static func captureSelection() async -> Capture? {
        await capture(app: NSWorkspace.shared.frontmostApplication)
    }

    /// Never reads our own windows (the self-test window lives in a separate host process, see SelfTestWindow).
    @MainActor static func capture(app: NSRunningApplication?) async -> Capture? {
        guard let app, app.processIdentifier != getpid() else { return nil }
        return await capture(pid: app.processIdentifier)
    }

    @MainActor static func capture(pid: pid_t) async -> Capture? {
        let result = await read(pid: pid)
        // No Highlighter runs for a capture without geometry, so nothing would end the read later: undo the wake now.
        if result?.hasGeometry != true { AXWake.restore(pid) }
        return result
    }

    @MainActor private static func read(pid: pid_t) async -> Capture? {
        let appElement = AXUIElementCreateApplication(pid)
        await AXWake.wake(appElement, pid: pid)
        let focused = axElement(appElement, kAXFocusedUIElementAttribute)
        let focusedWindow = axElement(appElement, kAXFocusedWindowAttribute)
        let window = focusedWindow ?? focused.flatMap { axElement($0, kAXWindowAttribute) }
            ?? (axAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        if let c = selection(appElement: appElement, pid: pid, focused: focused, focusedWindow: focusedWindow, window: window) {
            return withoutHiddenText(c)
        }
        let secure = focused.map(isSecure) ?? false   // never copy from, or read the value of, a password field
        if !secure {
            switch await copySelection(appElement: appElement) {
            case .text(let text):
                // Claude's chat Copy serialises its screen reader headings too; the tree cannot place them in a copy. Not
                // from a text field (the message box), whose text is all typed.
                let editable = focused.map { ["AXTextArea", "AXTextField", "AXComboBox"].contains(axAttribute($0, kAXRoleAttribute) as? String ?? "") } ?? false
                let net = isClaude(pid) && !editable ? HiddenText.safetyNet(text) : (text: text, removed: 0)
                let kept = net.removed > 0 && !net.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                var c = Capture(text: kept ? net.text : text, pid: pid, element: focused, window: window, selectionStart: nil, source: .copied)
                if kept { (c.hiddenRemoved, c.selected) = (net.removed, text) }
                return c
            case .clipboardChanged:
                Log.write("capture aborted: the clipboard changed while copying the selection")
                return nil   // someone else copied meanwhile: neither their text nor ours is safe to read
            case .nothing: break
            }
        }
        if !secure, let focused, let c = caretToEnd(focused, pid: pid, window: window) { return c }
        if let text = await gate.transaction({ clipboardText() }) {
            // An xterm.js terminal (Claude's, Codex's, VS Code's) draws its selection on a canvas that neither AX nor Edit ▸
            // Copy can reach. After the user's own ⌘C the text is on the clipboard and still on screen in this window, so
            // the locators may box it (node map, else OCR; a text found more than once is hidden). Other apps: no box.
            let terminal = focused.map(isXterm) ?? false
            return Capture(text: text, pid: pid, element: nil, window: terminal ? window : nil, selectionStart: nil, source: .clipboard)
        }
        return nil
    }

    static func isXterm(_ element: AXUIElement) -> Bool {
        (axAttribute(element, "AXDOMClassList") as? [String])?.contains("xterm-helper-textarea") == true
    }

    // MARK: - 1. AX selection

    /// The focused element's selection, else the first one a breadth-first search finds. A selection whose range does not
    /// cover exactly its text (PDFKit's AXPage reports {0,0}) is kept only as a fallback and the search goes on below
    /// it for an exact one (the page's AXStaticText reports the real range).
    private static func selection(appElement: AXUIElement, pid: pid_t, focused: AXUIElement?, focusedWindow: AXUIElement?,
                                  window: AXUIElement?) -> Capture? {
        func consider(_ element: AXUIElement, window: AXUIElement?) -> (capture: Capture, exact: Bool)? {
            guard !isSecure(element), let text = axAttribute(element, kAXSelectedTextAttribute) as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let range = selectedTextRange(of: element) else { return nil }
            let exact = range.location != kCFNotFound && range.length == text.utf16.count
            return (Capture(text: text, pid: pid, element: element, window: window, selectionStart: exact ? range.location : nil,
                            source: .accessibility), exact)
        }
        var loose: Capture?
        if let focused, let found = consider(focused, window: window) {
            if found.exact { return found.capture }
            loose = found.capture
        }
        // Some web views put the selection on a descendant, and an app with no key window has no focused element.
        // Chromium keeps one selection per web view, so with a focused selection only an exact copy of its text counts.
        let roots = focusedWindow.map { [($0, 3000)] }
            ?? ((axAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, 500) }
        for (root, limit) in roots {
            var queue = [root], visited = 0
            while !queue.isEmpty, visited < limit {
                let element = queue.removeFirst()
                visited += 1
                if isSecure(element) { continue }
                if let found = consider(element, window: root) {
                    if found.exact, loose == nil || loose?.text == found.capture.text { return found.capture }
                    if loose == nil { loose = found.capture }
                }
                if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
            }
        }
        return loose
    }

    // MARK: - 1b. Hidden text

    /// The selection without the text a web view exposes but never draws (`HiddenText`): Claude's chat puts a screen
    /// reader heading, "Claude responded: <its first sentence>", before every message and a hover toolbar with its
    /// timestamps after it, and Chromium's selected text includes both. The selection's text markers place each hidden
    /// node (`hiddenRanges`), and after any cut the button placeholders (U+FFFC) go too. In Claude without a usable
    /// tree, a heading straight before its own copy goes (`HiddenText.safetyNet`). Offsets into the element no longer hold after a cut,
    /// so `selectionStart` is then nil and `selected` keeps the original text (the node map and selection bounds
    /// place the words instead).
    static func withoutHiddenText(_ c: Capture) -> Capture {
        guard let element = c.element else { return withoutHiddenText(c, root: nil, selection: nil) }
        var area: AXUIElement? = element
        for _ in 0..<40 where area.map({ (axAttribute($0, kAXRoleAttribute) as? String) != "AXWebArea" }) == true {
            area = area.flatMap { axElement($0, kAXParentAttribute) }
        }
        let root = area ?? element
        let selection = [root, element].lazy.compactMap { axAttribute($0, "AXSelectedTextMarkerRange") }
            .first { CFGetTypeID($0) == AXTextMarkerRangeGetTypeID() }
        return withoutHiddenText(c, root: root, selection: selection.map { $0 as! AXTextMarkerRange })
    }

    /// The same for an explicit text marker range of `root` (the self-test's stand-in for a mouse selection).
    static func withoutHiddenText(_ c: Capture, root: AXUIElement?, selection: AXTextMarkerRange?) -> Capture {
        var text = c.text, removed = 0
        let claude = isClaude(c.pid)
        let walked = root.flatMap { root in selection.flatMap { hiddenRanges(root: root, selection: $0, text: text, chat: isClaudeChat(root, pid: c.pid)) } }
        if let walked {
            (text, removed) = HiddenText.cut(text, ranges: walked.ranges)
            // the toolbar's buttons leave their placeholders behind
            if removed > 0 { let objects = HiddenText.cut(text, ranges: HiddenText.objectReplacements(text)); (text, removed) = (objects.text, removed + objects.removed) }
        }
        if claude, walked?.complete != true {
            // No tree, or one not walked to the end, to place every heading by: the text-only net.
            (text, removed) = HiddenText.safetyNet(text, removed: removed)
        }
        guard removed > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return c }
        var out = Capture(text: text, pid: c.pid, element: c.element, window: c.window, selectionStart: nil, source: c.source)
        (out.hiddenRemoved, out.selected) = (removed, c.text)
        return out
    }

    /// The Claude desktop app, whose chat headings the text-only safety net knows; elsewhere repeated prose is prose.
    static func isClaude(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.anthropic.claudefordesktop"
    }

    /// Claude's own chat: a web area of the Claude app served from claude.ai. An artifact (claudeusercontent.com) or
    /// any other page is arbitrary content, where a toolbar or a zero-height box may be drawn.
    static func isClaudeChat(_ webArea: AXUIElement, pid: pid_t) -> Bool {
        isClaude(pid) && (axAttribute(webArea, "AXURL") as? URL)?.host == "claude.ai"
    }

    /// The ranges in `text` of the hidden nodes inside a web area's selection; nil when the selection's text is not
    /// `text`. Each node is placed on its own (`HiddenText.place`): exactly when its text-marker distances add up and
    /// its text is there, else only where `HiddenText.locate` finds its text once beside that place. A node whose
    /// distances cannot be read is left in. The walk stays near the selection: subtrees whose frame misses its bounds
    /// (by more than 60 pt, which keeps a toolbar above a message) are skipped.
    // ponytail: up to 4000 nodes, two AX calls each (role, classes) plus a frame for pruning, and five per hidden node;
    // Claude's chat window is about 400 nodes. Walk only the selection's common ancestor if big pages make this slow.
    private static func hiddenRanges(root: AXUIElement, selection: AXTextMarkerRange, text: String, chat: Bool) -> (ranges: [Range<Int>], complete: Bool)? {
        guard (axParameterizedAttribute(root, "AXStringForTextMarkerRange", parameter: selection) as? String) == text else { return nil }
        let length = text.utf16.count
        let selStart = AXTextMarkerRangeCopyStartMarker(selection), selEnd = AXTextMarkerRangeCopyEndMarker(selection)
        func distance(_ a: AXTextMarker, _ b: AXTextMarker) -> Int? {
            guard let range = axParameterizedAttribute(root, "AXTextMarkerRangeForUnorderedTextMarkers", parameter: [a, b] as CFArray) else { return nil }
            return (axParameterizedAttribute(root, "AXLengthForTextMarkerRange", parameter: range) as? NSNumber)?.intValue
        }
        var bounds: CGRect?
        if let value = axParameterizedAttribute(root, "AXBoundsForTextMarkerRange", parameter: selection), CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty { bounds = rect.insetBy(dx: -60, dy: -60) }
        }
        let ns = text as NSString
        var ranges: [Range<Int>] = [], complete = true
        var stack: [(AXUIElement, HiddenText.Visibility)] = [(root, .init(chat: chat))]
        var visited = 0
        while let (node, parent) = stack.popLast(), visited < 4000 {
            visited += 1
            if let bounds, let frame = axFrame(node), !frame.isEmpty, !frame.intersects(bounds) { continue }
            let visibility = parent.child(role: axAttribute(node, kAXRoleAttribute) as? String,
                                          classes: (axAttribute(node, "AXDOMClassList") as? [String]) ?? [])
            guard visibility.drawsText else {
                guard let own = axParameterizedAttribute(root, "AXTextMarkerRangeForUIElement", parameter: node),
                      CFGetTypeID(own) == AXTextMarkerRangeGetTypeID(),
                      let string = axParameterizedAttribute(root, "AXStringForTextMarkerRange", parameter: own) as? String else { complete = false; continue }
                guard !visibility.draws(string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let start = AXTextMarkerRangeCopyStartMarker(own as! AXTextMarkerRange)
                guard let d1 = distance(selStart, start), let d2 = distance(start, selEnd) else { complete = false; continue }
                guard let placed = HiddenText.place(d1: d1, d2: d2, length: length, nodeLength: string.utf16.count) else {
                    // near the selection but not placeable (both tolerant fits): unresolved, so the text net may run
                    if abs(d1 + d2 - length) <= 2 || abs(d2 - d1 - length) <= 2 { complete = false }
                    continue
                }
                // The part of the node's text that falls inside the selection, as the selection holds it.
                let part = (string as NSString).substring(with: NSRange(location: placed.skip, length: placed.range.count))
                if placed.exact, ns.substring(with: NSRange(location: placed.range.lowerBound, length: placed.range.count)) == part {
                    ranges.append(placed.range)
                } else if placed.skip == 0, placed.range.count == string.utf16.count,   // only a whole node is looked for
                          let found = HiddenText.locate(string, in: text, near: placed.range) {
                    ranges.append(found)
                } else {
                    complete = false
                }
                continue
            }
            if let children = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, visibility) })
            }
        }
        return (ranges, complete && stack.isEmpty)
    }

    // MARK: - 2. Copy

    enum Copied: Equatable { case text(String), nothing, clipboardChanged }

    /// Inside the gate: press the app's enabled ⌘C menu item through AX, wait for the pasteboard to change, read the
    /// string; the gate then restores the user's clipboard. No enabled item (nothing selected, or no Copy in the menu
    /// bar) is nothing: no synthetic ⌘C, whose handling could come after the transaction ended (Sol #22). A second
    /// change after the app's (Junior copying meanwhile) is `.clipboardChanged`: nothing is read, that copy is kept.
    @MainActor private static func copySelection(appElement: AXUIElement) async -> Copied {
        let gate = gate
        return await gate.transaction {
            guard let item = copyMenuItem(appElement), let before = gate.prepareToChange() else { return .nothing }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            return await readCopy(gate: gate, before: before)
        }
    }

    /// After Copy was pressed: the app's text, nothing (no change within 1 s, or an empty copy) or a clipboard that
    /// changed again after the app's change. A busy app can answer later (Sol #22), so with no change after 1 s the
    /// transaction stays open 1 s more, and a change in that grace is taken as the app's late copy: not read, but ours,
    /// so the gate restores the snapshot over it before the next transaction or the quit.
    // ponytail: a genuine user copy inside that grace would be undone; acceptable, the user just pressed the read
    // shortcut. A Copy handled more than 2 s late still lands after the transaction.
    @MainActor static func readCopy(gate: PasteboardGate, before: Int) async -> Copied {
        guard await gate.waitForChange(from: before, timeout: 1) else {
            guard gate.pasteboard.changeCount == before else { return .clipboardChanged }
            _ = await gate.waitForChange(from: before, timeout: 1)
            return .nothing
        }
        guard let text = gate.ownString() else { return .clipboardChanged }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .text(text)
    }

    /// The menu bar's enabled ⌘C item; nil when it has none or it is disabled. Two levels only: bar item → menu → item.
    private static func copyMenuItem(_ appElement: AXUIElement) -> AXUIElement? {
        guard let bar = axElement(appElement, kAXMenuBarAttribute) else { return nil }
        for barItem in (axAttribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for menu in (axAttribute(barItem, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (axAttribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    if (axAttribute(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "c",
                       (axAttribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,   // ⌘ alone
                       (axAttribute(item, kAXEnabledAttribute) as? Bool) == true { return item }
                }
            }
        }
        return nil
    }

    // MARK: - 3. Caret to end, 4. clipboard

    static func caretToEnd(_ element: AXUIElement, pid: pid_t, window: AXUIElement?) -> Capture? {
        guard let caret = selectedTextRange(of: element), caret.length == 0, caret.location != kCFNotFound,
              let value = axAttribute(element, kAXValueAttribute) as? String else { return nil }
        let ns = value as NSString
        guard caret.location < ns.length else { return nil }
        let wanted = NSRange(location: caret.location, length: min(ns.length - caret.location, maxCaretText))
        let text = ns.substring(with: ns.rangeOfComposedCharacterSequences(for: wanted))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Capture(text: text, pid: pid, element: element, window: window, selectionStart: caret.location, source: .cursor)
    }

    /// Read without writing; a password manager's concealed entry is never read aloud.
    @MainActor private static func clipboardText() -> String? {
        let pasteboard = gate.pasteboard
        guard !(pasteboard.types ?? []).contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Helpers

    static func isSecure(_ element: AXUIElement) -> Bool {
        (axAttribute(element, kAXRoleAttribute) as? String) == "AXSecureTextField"
            || (axAttribute(element, kAXSubroleAttribute) as? String) == "AXSecureTextField"
    }

    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        guard let value = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

// MARK: - AX C API helpers, shared with the locators

/// Copies an AX attribute, returning nil on any error (no attribute, unsupported, etc).
func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Copies a parameterised AX attribute, returning nil on any error.
func axParameterizedAttribute(_ element: AXUIElement, _ attribute: String, parameter: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else { return nil }
    return value
}

/// AXPosition + AXSize, in AX (top-left origin) screen coordinates.
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), let s = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

/// `AXBoundsForRange` in AX (top-left origin) coordinates.
func axBounds(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
    var range = CFRange(location: location, length: length)
    guard let parameter = AXValueCreate(.cfRange, &range),
          let value = axParameterizedAttribute(element, "AXBoundsForRange", parameter: parameter),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetType(value as! AXValue) == .cgRect, AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
    return rect
}
