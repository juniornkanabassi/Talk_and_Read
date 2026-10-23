// Records a key chord for one Settings shortcut: shows its key caps (or "Record shortcut" when off); click to listen.
// Esc cancels, Delete turns the shortcut off, a refused combination (no ⌃ ⌥ ⌘, reserved by macOS, used by another
// action) shows why and keeps listening. Owned by WP6; reworked for the Shortcuts page (S2).
import AppKit
import SwiftUI
import TalkReadCore

/// Which recorder is listening, by settings key: one at a time, and the global hotkeys stand down meanwhile (Sol #15),
/// so recording ⌃A does not also start a read. `refusal` explains the last combination the listening one refused.
@MainActor final class RecorderFocus: ObservableObject {
    static let shared = RecorderFocus()
    @Published private(set) var active: String?
    @Published var refusal: String?

    /// Takes over from any other recorder (which then stops listening).
    func begin(_ key: String) {
        active = key
        refusal = nil
        AppModel.shared.hotkeysPaused = true
    }

    /// Finish, cancel or disappear; ignored unless `key` is the one listening.
    func end(_ key: String) {
        guard active == key else { return }
        active = nil
        refusal = nil
        AppModel.shared.hotkeysPaused = false
    }
}

struct ShortcutRecorder: View {
    /// Settings key of the shortcut ("readShortcut").
    let key: String
    @Binding var shortcut: TalkReadCore.Settings.Shortcut
    /// Why a combination cannot be used here, or nil when it can.
    let check: (TalkReadCore.Settings.Shortcut) -> String?
    @ObservedObject private var focus = RecorderFocus.shared
    @State private var monitor: Any?
    private var recording: Bool { focus.active == key }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording ? focus.end(key) : focus.begin(key) } label: {
                Group {
                    if recording {
                        Text("Press the new keys…").font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).frame(minHeight: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                    } else if shortcut.isOff {
                        Text("Record shortcut").font(.callout).foregroundStyle(.secondary).frame(minHeight: 24)
                    } else {
                        KeyCaps(display: shortcut.display)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Esc cancels; Delete turns the shortcut off" : "Click, then press the new keys")
            .accessibilityLabel(recording ? "Listening for a new shortcut" : shortcut.isOff ? "No shortcut. Record a shortcut" : "Shortcut \(shortcut.display). Record a new one")
            if recording {
                Text(focus.refusal ?? "Esc cancels · Delete turns it off")
                    .font(.caption).foregroundStyle(focus.refusal == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: recording) { _, on in on ? startMonitor() : stopMonitor() }
        .onDisappear {
            stopMonitor()
            focus.end(key)
        }
        // Leaving the app cancels, so the hotkeys are never left paused behind a forgotten recorder.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in focus.end(key) }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [focus, key] event in
            let plain = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
            if plain, event.keyCode == 53 {
                focus.end(key)                                       // Esc cancels
            } else if plain, event.keyCode == 51 || event.keyCode == 117 {
                shortcut = .off                                      // Delete turns it off
                focus.end(key)
            } else {
                let s = Self.make(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
                if let why = check(s) { focus.refusal = why } else { shortcut = s; focus.end(key) }
            }
            return nil   // swallow while recording
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A shortcut from a key event. `modifiers` uses CGEventFlags bits, which match NSEvent's; whether it is usable is
    /// `Settings.refusal`'s call.
    static func make(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> TalkReadCore.Settings.Shortcut {
        let mods = flags.intersection([.control, .option, .shift, .command])
        var glyphs = ""
        if mods.contains(.control) { glyphs += "⌃" }
        if mods.contains(.option) { glyphs += "⌥" }
        if mods.contains(.shift) { glyphs += "⇧" }
        if mods.contains(.command) { glyphs += "⌘" }
        return TalkReadCore.Settings.Shortcut(keyCode: keyCode, modifiers: UInt64(mods.rawValue), display: glyphs + keyName(keyCode, characters))
    }

    static func keyName(_ keyCode: UInt16, _ characters: String?) -> String {
        let named: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = named[keyCode] { return name }
        return (characters ?? "").uppercased().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Key \(keyCode)" : (characters ?? "").uppercased()
    }
}
