// Types text into the focused field by pasting (PLAN decision 7): refuse secure fields, add a leading space when the
// caret follows a word, paste with a tagged ⌘V, and let PasteboardGate restore the user's clipboard afterwards.
import AppKit
import ApplicationServices
import Carbon

enum InsertResult: Equatable { case inserted, refusedSecure, failed(String) }

enum Inserter {
    /// The gate every paste goes through; the self-test swaps in a private pasteboard.
    @MainActor static var gate = PasteboardGate.shared

    /// With `targetPID`, the paste chord goes to that process only (never the HID stream), so a test can never type
    /// into another app. Task cancellation and `isCurrent` are checked inside the pasteboard transaction with nothing
    /// awaited between them and the paste, so text whose utterance was cancelled meanwhile is never typed; once ⌘V is
    /// out, the 500 ms wait before the restore runs in full even if the task is cancelled.
    @MainActor static func insert(_ text: String, targetPID: pid_t? = nil, isCurrent: @MainActor () -> Bool = { true }) async -> InsertResult {
        guard !text.isEmpty else { return .failed("Nothing to type") }
        guard CGPreflightPostEventAccess() else { return .failed("Talk and Read needs Accessibility to type") }
        let gate = gate
        return await gate.transaction {
            if IsSecureEventInputEnabled() { return .refusedSecure }
            let field = focusedField(pid: targetPID)
            if field.secure { return .refusedSecure }
            let typed = needsLeadingSpace(after: field.previous, text: text) ? " " + text : text
            guard !Task.isCancelled, isCurrent() else { return .failed("Cancelled") }
            gate.write(typed)
            guard postPaste(to: targetPID) else { return .failed("Could not send the paste keystroke") }
            // Let the app read the pasteboard before it is restored. Not `Task.sleep`: cancellation would end it at once.
            await withCheckedContinuation { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.resume() } }
            return .inserted
        }
    }

    /// Whether the focused field is secure, and the UTF-16 unit before its caret (nil = unknown or at the start).
    @MainActor static func focusedField(pid: pid_t?) -> (secure: Bool, previous: unichar?) {
        if pid == getpid() { return ownFocusedField() }
        let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let element: AXUIElement = attribute(root, kAXFocusedUIElementAttribute) else { return (false, nil) }
        let secure = [kAXRoleAttribute, kAXSubroleAttribute].contains { (attribute(element, $0) as String?) == kAXSecureTextFieldSubrole }
        guard !secure, let value: String = attribute(element, kAXValueAttribute),
              let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return (secure, nil) }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return (false, nil) }
        let string = value as NSString
        return (false, range.location > 0 && range.location <= string.length ? string.character(at: range.location - 1) : nil)
    }

    /// Our own windows (the reader, onboarding, the self-test): AppKit knows the focus even when the window is not
    /// key, where an AX query of our own process returns nothing.
    @MainActor private static func ownFocusedField() -> (secure: Bool, previous: unichar?) {
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.firstResponder is NSTextView }
        guard let editor = window?.firstResponder as? NSTextView else { return (false, nil) }
        if editor.delegate is NSSecureTextField { return (true, nil) }
        let caret = editor.selectedRange().location
        let string = editor.string as NSString
        return (false, caret > 0 && caret <= string.length ? string.character(at: caret - 1) : nil)
    }

    /// A space before the text unless the caret is at the start, after whitespace or an opening bracket/quote, or the
    /// text itself starts with punctuation.
    static func needsLeadingSpace(after previous: unichar?, text: String) -> Bool {
        guard let previous, let first = text.unicodeScalars.first else { return false }
        if let scalar = Unicode.Scalar(previous),
           CharacterSet.whitespacesAndNewlines.contains(scalar) || "([{\"'“‘/".unicodeScalars.contains(scalar) { return false }
        return !CharacterSet.punctuationCharacters.contains(first)
    }

    /// ⌘ down, V down, V up, ⌘ up, with ⌘ released explicitly, all tagged.
    @MainActor static func postPaste(to pid: pid_t?) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let v = keyCode(for: "v") ?? 9   // 9 = ANSI V
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [(55, true, .maskCommand), (v, true, .maskCommand),
                                                         (v, false, .maskCommand), (55, false, [])]
        for (key, down, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: PasteboardGate.eventTag)
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
        return true
    }

    /// The key code that types `character` in the current keyboard layout (AZERTY, Dvorak, ...).
    @MainActor static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let wanted = character.utf16.first
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == wanted { return CGKeyCode(code) }
            }
            return nil
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
