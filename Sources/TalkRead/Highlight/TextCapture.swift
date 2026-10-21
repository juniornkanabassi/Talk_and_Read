// What to read when the user presses Read (PLAN decision 6): AX selection → Edit ▸ Copy (else ⌘C) inside the
// PasteboardGate → caret to end of the focused text → the existing clipboard → nil. AX part ported from ReadAlong.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
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
            switch await copySelection(appElement: appElement, pid: pid) {
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

    /// Inside the gate: press the app's ⌘C menu item through AX (no menu item → post ⌘C to the app), wait ≤ 300 ms for
    /// the pasteboard to change, read the string; the gate then restores the user's clipboard. A second change after
    /// the app's (Junior copying meanwhile) is `.clipboardChanged`: nothing is read and that newer copy is kept.
    @MainActor private static func copySelection(appElement: AXUIElement, pid: pid_t) async -> Copied {
        let gate = gate
        return await gate.transaction {
            let before = gate.pasteboard.changeCount
            switch copyMenuItem(appElement) {
            case .some(let item?): AXUIElementPerformAction(item, kAXPressAction as CFString)
            case .some(nil): return .nothing   // the app has Copy but disables it: nothing is selected
            case nil: postCommandC(to: pid)
            }
            return await readCopy(gate: gate, before: before)
        }
    }

    /// After the copy was requested: the app's text, nothing (no change in 300 ms, or an empty copy) or a clipboard
    /// that changed again after the app's change.
    @MainActor static func readCopy(gate: PasteboardGate, before: Int) async -> Copied {
        guard await gate.waitForChange(from: before, timeout: 0.3) else {
            return gate.pasteboard.changeCount == before ? .nothing : .clipboardChanged
        }
        guard let text = gate.ownString() else { return .clipboardChanged }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .text(text)
    }

    /// nil: the menu bar has no ⌘C item. .some(nil): it has one but it is disabled. Two levels only: bar item → menu → item.
    private static func copyMenuItem(_ appElement: AXUIElement) -> AXUIElement?? {
        guard let bar = axElement(appElement, kAXMenuBarAttribute) else { return nil }
        var disabled = false
        for barItem in (axAttribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for menu in (axAttribute(barItem, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (axAttribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    guard (axAttribute(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "c",
                          (axAttribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0 // ⌘ alone
                    else { continue }
                    if (axAttribute(item, kAXEnabledAttribute) as? Bool) == true { return .some(item) }
                    disabled = true
                }
            }
        }
        return disabled ? .some(nil) : nil
    }

    /// ⌘C as key down/up to the app only, on the key that types "c" in the current layout, tagged so our tap ignores it.
    @MainActor private static func postCommandC(to pid: pid_t) {
        let key = keyCode(typing: "c") ?? CGKeyCode(kVK_ANSI_C)
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: PasteboardGate.eventTag)
            event.postToPid(pid)
        }
    }

    /// The virtual key code that types `character` in the current keyboard layout (Dvorak's "c" is not kVK_ANSI_C).
    @MainActor static func keyCode(typing character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length) == character { return CGKeyCode(code) }
            }
            return nil
        }
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
