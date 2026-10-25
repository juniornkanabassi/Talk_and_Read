// Waking an app's accessibility tree for a read, and putting it back (E8). Chromium and Electron build their tree for
// AXManualAccessibility, which is harmless elsewhere and stays set. AXEnhancedUserInterface can upset window managers
// and animations, so it is set only for an app that still exposes no text after that, and reverted when the read ends.
import AppKit
import ApplicationServices

@MainActor enum AXWake {
    private static let enhanced = "AXEnhancedUserInterface" as CFString
    private static let textRoles: Set<String> = ["AXWebArea", "AXStaticText", "AXTextArea", "AXTextField"]
    /// pids whose AXEnhancedUserInterface we turned on. The value to restore is always false: an app that already had it
    /// on is never touched, so it never enters the ledger.
    private static var ledger = Set<pid_t>()

    static func isWoken(_ pid: pid_t) -> Bool { ledger.contains(pid) }

    static func wake(_ app: AXUIElement, pid: pid_t) async {
        prune()
        AXUIElementSetMessagingTimeout(app, 0.25)   // its writes and read-backs too: a hung app must not stall the main thread
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // The probe is main-actor work across a process boundary: 250 ms in total, and a short timeout per call, on an
        // element of its own so the caller's keeps its timeout. Out of time counts as "no text found".
        let deadline = ContinuousClock.now + .milliseconds(250)
        let probe = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(probe, 0.1)
        for attempt in 0..<6 {
            if exposesText(probe, until: deadline) { return }
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
        if !isOn(app) { ledger.remove(pid) }   // read-back, not the return code; still on keeps the pid for `restoreAll` at quit
    }

    /// Every app we woke, for a caller that has no pid (app quit).
    static func restoreAll() { for pid in ledger { restore(pid) } }   // iterates a copy: restore removes from the ledger

    /// A process that has exited has nothing left to restore.
    private static func prune() {
        ledger = ledger.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
    }

    /// An AXWebArea or a text element within the focused (else first) window; a bounded breadth-first look, by count and by time.
    private static func exposesText(_ app: AXUIElement, until deadline: ContinuousClock.Instant) -> Bool {
        guard let window = axElement(app, kAXFocusedWindowAttribute) ?? (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        else { return false }
        // A titled window always has its title as an AXStaticText child; that is not the app's text.
        var queue = ((axAttribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
            .filter { (axAttribute($0, kAXRoleAttribute) as? String) != "AXStaticText" }
        var visited = 0
        while !queue.isEmpty, visited < 300, ContinuousClock.now < deadline {
            let node = queue.removeFirst()
            visited += 1
            if let role = axAttribute(node, kAXRoleAttribute) as? String, textRoles.contains(role) { return true }
            queue += (axAttribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return false
    }
}
