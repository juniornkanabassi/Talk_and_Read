// Records a key chord for a Settings shortcut: needs at least one of ⌃ ⌥ ⌘ plus a key, shows glyphs, warns on clashes,
// Esc cancels, the clear button turns the shortcut off (empty `display`, keyCode 0, no modifiers). Owned by WP6.
import AppKit
import SwiftUI
import TalkReadCore

struct ShortcutRecorder: View {
    @Binding var shortcut: TalkReadCore.Settings.Shortcut
    /// Name of another action using the same chord, if any.
    let clash: String?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button { recording.toggle() } label: {
                    Text(recording ? "Type a shortcut…" : (shortcut.display.isEmpty ? "Off" : shortcut.display))
                        .font(.body.monospaced())
                        .frame(minWidth: 120)
                        .foregroundStyle(recording ? .secondary : .primary)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(shortcut.display.isEmpty ? "No shortcut. Record a shortcut" : "Shortcut \(shortcut.display). Record a new one")
                if !shortcut.display.isEmpty, !recording {
                    Button { shortcut = TalkReadCore.Settings.Shortcut(keyCode: 0, modifiers: 0, display: "") } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Turn this shortcut off").accessibilityLabel("Clear shortcut")
                }
            }
            if let clash { Text("Also used by \(clash)").font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: recording) { _, on in on ? startMonitor() : stopMonitor() }
        .onDisappear(perform: stopMonitor)
    }

    private func startMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty {
                recording = false   // Esc alone cancels
            } else if let s = Self.make(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) {
                shortcut = s
                recording = false
            } else {
                NSSound.beep()   // needs ⌃, ⌥ or ⌘
            }
            return nil   // swallow while recording
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A shortcut from a key event, or nil without ⌃ ⌥ or ⌘. `modifiers` uses CGEventFlags bits, which match NSEvent's.
    static func make(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> TalkReadCore.Settings.Shortcut? {
        let mods = flags.intersection([.control, .option, .shift, .command])
        guard !mods.intersection([.control, .option, .command]).isEmpty else { return nil }
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
