// Opt-in learning (DictationController.learnCorrections, off by default): reads the field a dictation went into right
// after the paste, then once a second while it keeps focus (at most `seconds`), and hands both readings to AutoLearn.
// Read-only Accessibility; never a secure field or while secure input is on; another app, another field or a field
// over 100k characters ends the watch. Only the word pairs are kept, never the field's text.
import AppKit
import ApplicationServices
import Carbon
import TalkReadCore

@MainActor enum CorrectionWatcher {
    /// The re-spellings made inside `text` (just typed by the inserter) before focus left the field or `seconds` ran
    /// out; [] when the field cannot be read. Cancelling ends the watch early with the readings so far.
    static func watch(text: String, seconds: Double = 15) async -> [AutoLearn.Correction] {
        guard let first = snapshot(), let range = locate(text, in: first) else { return [] }
        var last = first
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            guard let now = snapshot(), now.pid == first.pid, CFEqual(now.element, first.element) else { break }
            last = now
        }
        return AutoLearn.corrections(before: first.value, after: last.value, inserted: range)
    }

    private struct Snapshot { let element: AXUIElement; let pid: pid_t; let value: String; let caret: Int }

    /// The focused text element of another app, when it is not secure and its text is readable.
    private static func snapshot() -> Snapshot? {
        guard !IsSecureEventInputEnabled() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        let secure = [kAXRoleAttribute, kAXSubroleAttribute].contains { (attribute(element, $0) as String?) == kAXSecureTextFieldSubrole }
        guard !secure, let value: String = attribute(element, kAXValueAttribute), (value as NSString).length <= 100_000,
              let selection: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection, .cfRange, &range) else { return nil }
        return Snapshot(element: element, pid: pid, value: value, caret: range.location)
    }

    /// Where the dictation sits: ending at the caret just after the paste, else its last occurrence.
    private static func locate(_ text: String, in s: Snapshot) -> Range<Int>? {
        let value = s.value as NSString, n = (text as NSString).length
        if s.caret >= n, s.caret <= value.length, value.substring(with: NSRange(location: s.caret - n, length: n)) == text {
            return s.caret - n..<s.caret
        }
        let r = value.range(of: text, options: .backwards)
        return r.location == NSNotFound ? nil : r.location..<r.location + r.length
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
