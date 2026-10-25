// Waking an app's accessibility tree for a read, and putting it back (E8). Chromium and Electron build their tree for
// AXManualAccessibility, which is harmless elsewhere and stays set. AXEnhancedUserInterface can upset window managers
// and animations, so it is set only for an app that still exposes no word geometry after that, and reverted when the
// read ends. Geometry, not text: OpenAI's ChatGPT app exposes its text for AXManualAccessibility but answers
// AXBoundsForRange only once AXEnhancedUserInterface is on, so a text-only test left it without a highlight (work Mac, 25 Oct).
import AppKit
import ApplicationServices

@MainActor enum AXWake {
    private static let enhanced = "AXEnhancedUserInterface" as CFString
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]
    /// pids whose AXEnhancedUserInterface we turned on. The value to restore is always false: an app that already had it
    /// on is never touched, so it never enters the ledger.
    private static var ledger = Set<pid_t>()

    static func isWoken(_ pid: pid_t) -> Bool { ledger.contains(pid) }

    static func wake(_ caller: AXUIElement, pid: pid_t) async {
        prune()
        // Writes and read-backs go through an element of our own with a short timeout, so a hung app cannot stall the
        // main thread and the caller's element (a selection read's, which goes on to use it) keeps its own timeout.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // The probe is main-actor work across a process boundary: 250 ms in total, and a short timeout per call, on an
        // element of its own so the caller's keeps its timeout. Out of time counts as "no text found".
        let deadline = ContinuousClock.now + .milliseconds(250)
        let probe = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(probe, 0.1)
        for attempt in 0..<6 {
            // Scoped short timeout for the whole walk: the window and children it reaches are other elements than `probe`.
            if PointerCapture.bounded(0.25, { exposesGeometry(probe, until: deadline) }) { return }
            guard attempt < 5, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !ledger.contains(pid), !isOn(app) else { return }
        let set = AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue)
        // The read-back decides: AppKit applies the value yet answers notImplemented. A read-back that fails after a
        // reported success is not "off": ledger it, so quit retries the restore.
        if isOn(app) || (set == .success && axAttribute(app, enhanced as String) == nil) { ledger.insert(pid) }
    }

    // ponytail: an unreadable previous value counts as off; setting fails for such apps anyway, so nothing is lost.
    private static func isOn(_ app: AXUIElement) -> Bool { (axAttribute(app, enhanced as String) as? Bool) == true }

    /// The read on `pid` ended (or never started): put AXEnhancedUserInterface back. A no-op for an app never woken.
    static func restore(_ pid: pid_t) {
        prune()
        guard ledger.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        _ = AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse)
        // Only a read-back of "off" clears it: still on, or no answer in time, keeps the pid for `restoreAll` at quit.
        if (axAttribute(app, enhanced as String) as? Bool) == false { ledger.remove(pid) }
    }

    /// Every app we woke, for a caller that has no pid (app quit).
    static func restoreAll() { for pid in ledger { restore(pid) } }   // iterates a copy: restore removes from the ledger

    /// A process that has exited has nothing left to restore.
    private static func prune() {
        ledger = ledger.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
    }

    /// A text element with text that answers AXBoundsForRange, within the focused (else first) window; a bounded
    /// breadth-first look, by count and by time.
    private static func exposesGeometry(_ app: AXUIElement, until deadline: ContinuousClock.Instant) -> Bool {
        guard let window = (axElement(app, kAXFocusedWindowAttribute) ?? (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first)
            .map(short) else { return false }
        // A titled window always has its title as an AXStaticText child; that is not the app's text.
        var queue = ((axAttribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(short)
            .filter { (axAttribute($0, kAXRoleAttribute) as? String) != "AXStaticText" }
        var visited = 0
        while !queue.isEmpty, visited < 300, ContinuousClock.now < deadline {
            let node = queue.removeFirst()
            visited += 1
            if let role = axAttribute(node, kAXRoleAttribute) as? String, textRoles.contains(role),
               let value = axAttribute(node, kAXValueAttribute) as? String, !value.isEmpty,
               let rect = axBounds(node, location: 0, length: 1), rect.width > 0, rect.height > 0 { return true }
            queue += ((axAttribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(short)
        }
        return false
    }

    /// The probe's short timeout, per element: a timeout set on the application element covers only that element.
    private static func short(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }
}
