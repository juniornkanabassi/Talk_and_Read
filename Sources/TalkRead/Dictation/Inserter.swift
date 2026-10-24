// Types text into the focused field by pasting (PLAN decision 7): refuse secure fields, add a leading space when the
// caret follows a word, keep text for a terminal or a single-line field on one line, at the end of a dictation paste only
// when the focus can take text, paste with a tagged ⌘V, and let PasteboardGate restore the user's clipboard afterwards.
import AppKit
import ApplicationServices
import Carbon

enum InsertResult: Equatable { case inserted, refusedSecure, failed(String) }

enum Inserter {
    /// What the inserter knows about the focus (see `focusedField`).
    typealias Focus = (secure: Bool, previous: unichar?, terminal: Bool, singleLine: Bool, takesText: Bool?)
    /// The gate every paste goes through; the self-test swaps in a private pasteboard.
    @MainActor static var gate = PasteboardGate.shared
    /// The focus query; the self-test swaps in a fixed answer.
    @MainActor static var focus: @MainActor (_ pid: pid_t?) -> Focus = { focusedField(pid: $0) }
    /// Why the end of a dictation typed nothing: the focus cannot take text.
    static let noField = "No text field to type into"

    /// With `targetPID`, the paste chord goes to that process only (never the HID stream), so a test can never type
    /// into another app. Task cancellation and `isCurrent` are checked inside the pasteboard transaction with nothing
    /// awaited between them and the paste, so text whose utterance was cancelled meanwhile is never typed; once ⌘V is
    /// out, the 500 ms wait before the restore runs in full even if the task is cancelled. With `requireField`, a focus
    /// that cannot take text (`takesText == false`) fails with `noField`: no ⌘V, the clipboard untouched.
    @MainActor static func insert(_ text: String, targetPID: pid_t? = nil, requireField: Bool = false,
                                  isCurrent: @MainActor () -> Bool = { true }) async -> InsertResult {
        guard !text.isEmpty else { return .failed("Nothing to type") }
        guard CGPreflightPostEventAccess() else { return .failed("Talk & Read needs Accessibility to type") }
        let gate = gate
        return await gate.transaction {
            if IsSecureEventInputEnabled() { return .refusedSecure }
            let field = focus(targetPID)
            if field.secure { return .refusedSecure }
            if requireField, field.takesText == false { return .failed(noField) }
            let body = field.terminal || field.singleLine ? oneLine(text) : text
            let typed = needsLeadingSpace(after: field.previous, text: body) ? " " + body : body
            guard !Task.isCancelled, isCurrent() else { return .failed("Cancelled") }
            // Refused while quitting: the pasteboard still holds the user's own clipboard, so no ⌘V may go out.
            guard gate.write(typed) != nil else { return .failed("Talk & Read is quitting") }
            guard postPaste(to: targetPID) else { return .failed("Could not send the paste keystroke") }
            // Let the app read the pasteboard before it is restored. Not `Task.sleep`: cancellation would end it at once.
            await withCheckedContinuation { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.resume() } }
            return .inserted
        }
    }

    /// Whether the focused field is secure, whether it is a terminal, whether it is a single-line field, the UTF-16 unit
    /// before its caret (nil = unknown or at the start), and whether it can take text (`takesText`; nil = unknown).
    /// Normal dictation passes no PID: the frontmost app then decides whether the focus is one of our own fields
    /// (`frontmost` and `ownEditor` are swapped by the self-test).
    @MainActor static func focusedField(pid: pid_t?, frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                                        ownEditor: @MainActor () -> NSTextView? = { Inserter.ownEditor() }) -> Focus {
        if (pid ?? frontmost()) == getpid() {
            // Our own windows: no text view in focus (a web view, a button) is not ours to judge, so unknown.
            guard let editor = ownEditor() else { return (false, nil, false, false, nil) }
            let own = describe(editor)
            return (own.secure, own.previous, false, own.singleLine, editor.isEditable)
        }
        let root = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let element: AXUIElement = attribute(root, kAXFocusedUIElementAttribute) else { return (false, nil, false, false, nil) }
        let role: String? = attribute(element, kAXRoleAttribute), subrole: String? = attribute(element, kAXSubroleAttribute)
        let secure = role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
        let terminal = isTerminal(element)
        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let single = isSingleLine(role: role, subrole: subrole, editable: settable.boolValue)
        let rangeValue: AXValue? = attribute(element, kAXSelectedTextRangeAttribute)
        var takes = takesText(role: role, subrole: subrole, editable: settable.boolValue, caret: rangeValue != nil, terminal: terminal)
        // Inside a web app's editable region (contenteditable): whatever the focused node calls itself, it takes text.
        if takes == false, (attribute(element, "AXEditableAncestor") as AXUIElement?) != nil { takes = true }
        guard !secure, let rangeValue else { return (secure, nil, terminal, single, takes) }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location > 0 else { return (false, nil, terminal, single, takes) }
        // One character before the caret, not the whole text: a long document's value can take most of the timeout.
        var before = CFRange(location: range.location - 1, length: 1)
        if let query = AXValueCreate(.cfRange, &before), let character: String = parameterized(element, kAXStringForRangeParameterizedAttribute, query),
           let unit = character.utf16.first {
            return (false, unit, terminal, single, takes)
        }
        guard let value: String = attribute(element, kAXValueAttribute) else { return (false, nil, terminal, single, takes) }
        let string = value as NSString
        return (false, range.location <= string.length ? string.character(at: range.location - 1) : nil, terminal, single, takes)
    }

    /// Whether a paste has somewhere to land. true: a text field or area, a search field, an editable combo box, a
    /// terminal, or anything with a caret whose value can be set. nil when the app does not say: no role, or a generic
    /// group, window or scroll area (what an Electron app whose AX tree is asleep, or a terminal without AX, reports), so
    /// the paste goes ahead as before and the pill's Copy and tip cover a miss. false for anything else AX names: a web
    /// page with no field focused, a list, a table, a button, an image, static text.
    static func takesText(role: String?, subrole: String?, editable: Bool, caret: Bool, terminal: Bool) -> Bool? {
        if terminal || role == kAXTextAreaRole || isSingleLine(role: role, subrole: subrole, editable: editable) || (caret && editable) { return true }
        guard let role, ![kAXGroupRole, kAXWindowRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXUnknownRole, kAXApplicationRole].contains(role)
        else { return nil }
        return false
    }

    /// A text field, search field or editable combo box takes one line: a paragraph break would press Return in it (search,
    /// submit). A combo box that cannot be typed into is not a text field (`editable` = its value can be set).
    static func isSingleLine(role: String?, subrole: String?, editable: Bool = false) -> Bool {
        role == kAXTextFieldRole || subrole == kAXSearchFieldSubrole || role == "AXSearchField" || (role == kAXComboBoxRole && editable)
    }

    /// The field editor of one of our own text fields or combo boxes is an NSTextView, but its owner takes one line; a text
    /// view of our own that is not a field editor keeps its breaks.
    static func isSingleLine(editor: NSTextView) -> Bool {
        editor.isFieldEditor && (editor.delegate is NSTextField || editor.delegate is NSComboBox)
    }

    /// Terminal apps, and the terminal panel of an editor such as VS Code (its input is described as "Terminal …").
    static let terminalApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                            "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]

    @MainActor private static func isTerminal(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, terminalApps.contains(id) { return true }
        return [kAXDescriptionAttribute, kAXTitleAttribute].contains { ((attribute(element, $0) as String?) ?? "").hasPrefix("Terminal") }
    }

    /// A terminal runs every pasted line as a command when its shell has no bracketed paste (macOS's bash 3.2, ssh, REPLs),
    /// and a single-line field submits on one: line breaks become spaces, so a dictation never presses Return.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]*\\n+[ \\t]*", with: " ", options: .regularExpression)
    }

    /// Why typing was refused: a terminal's Secure Keyboard Entry (a setting the user can turn off) or a password field.
    @MainActor static func refusal() -> String {
        if IsSecureEventInputEnabled(), let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let pid = session["kCGSSessionSecureInputPID"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           terminalApps.contains(app.bundleIdentifier ?? "") {
            return "Not typed: Secure Keyboard Entry is on in \(app.localizedName ?? "the terminal")"
        }
        return "Not typed: password field"
    }

    /// Our own windows (the reader, onboarding, the self-test): AppKit knows the focus even when the window is not
    /// key, where an AX query of our own process returns nothing.
    @MainActor static func ownEditor() -> NSTextView? {
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.firstResponder is NSTextView }
        return window?.firstResponder as? NSTextView
    }

    /// What the inserter needs to know about the text view that has our own focus.
    @MainActor static func describe(_ editor: NSTextView) -> (secure: Bool, previous: unichar?, singleLine: Bool) {
        if editor.delegate is NSSecureTextField { return (true, nil, true) }
        let caret = editor.selectedRange().location
        let string = editor.string as NSString
        return (false, caret > 0 && caret <= string.length ? string.character(at: caret - 1) : nil, isSingleLine(editor: editor))
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

    private static func parameterized<T>(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value as? T
    }
}
