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

    /// Sources whose text has a place on screen; the Highlighter draws only for these.
    var hasGeometry: Bool { [.accessibility, .copied, .cursor, .ocr].contains(source) }
}

enum TextCapture {
    /// The gate the copy and clipboard steps use; the self-test swaps in a private pasteboard.
    static var gate = PasteboardGate.shared
    /// pids already woken with AXEnhancedUserInterface / AXManualAccessibility this launch.
    private static var wokenPIDs = Set<pid_t>()
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
        let appElement = AXUIElementCreateApplication(pid)
        wake(appElement, pid: pid)
        let focused = axElement(appElement, kAXFocusedUIElementAttribute)
        let focusedWindow = axElement(appElement, kAXFocusedWindowAttribute)
        let window = focusedWindow ?? focused.flatMap { axElement($0, kAXWindowAttribute) }
            ?? (axAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        if let c = selection(appElement: appElement, pid: pid, focused: focused, focusedWindow: focusedWindow, window: window) { return c }
        let secure = focused.map(isSecure) ?? false   // never copy from, or read the value of, a password field
        if !secure {
            switch await copySelection(appElement: appElement) {
            case .text(let text):
                return Capture(text: text, pid: pid, element: focused, window: window, selectionStart: nil, source: .copied)
            case .clipboardChanged:
                Log.write("capture aborted: the clipboard changed while copying the selection")
                return nil   // someone else copied meanwhile: neither their text nor ours is safe to read
            case .nothing: break
            }
        }
        if !secure, let focused, let c = caretToEnd(focused, pid: pid, window: window) { return c }
        if let text = await gate.transaction({ clipboardText() }) {
            return Capture(text: text, pid: pid, element: nil, window: nil, selectionStart: nil, source: .clipboard)
        }
        return nil
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

    /// Chromium and Electron build their AX tree only for assistive clients that ask (ReadAlong 0.1).
    private static func wake(_ appElement: AXUIElement, pid: pid_t) {
        guard !wokenPIDs.contains(pid) else { return }
        wokenPIDs.insert(pid)
        _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

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
