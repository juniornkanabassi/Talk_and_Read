// The status item's menu, rebuilt each time it opens. The lead attaches `menu` to the NSStatusItem. Owned by WP6.
import AppKit
import TalkReadCore

@MainActor final class MenuBarMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model: AppModel
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private let openOnboarding: () -> Void
    // ponytail: recent voices are remembered for this launch only; persist in Settings if wanted across launches.
    private var recentVoices: [String] = []

    init(model: AppModel, openMain: @escaping () -> Void, openSettings: @escaping () -> Void, openOnboarding: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        self.openSettings = openSettings
        self.openOnboarding = openOnboarding
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func rebuild() {
        menu.removeAllItems()
        let s = model.settings
        let state = model.session?.state
        let reading = state == .playing || state == .preparing

        add("Read selection", s.readShortcut) { [model] in model.readSelection() }
        add(state == .paused ? "Resume" : "Pause", s.pauseShortcut, enabled: reading || state == .paused) { [model] in model.togglePause() }
        add("Replay last", enabled: !model.recentReads.isEmpty) { [model] in
            if let text = model.recentReads.first?.text { try? model.speak(text, title: nil, caller: "user") }
        }
        add("Screenshot and listen", s.screenshotShortcut) { [model] in model.readScreenshot() }
        menu.addItem(.separator())

        let speed = Double(s.speed)
        let speeds = NSMenu()
        for p in Theme.quickSpeeds { add(Theme.speed(p), on: abs(p - speed) < 0.001, to: speeds) { [model] in model.setSpeed(Float(p)) } }
        submenu("Speed  \(Theme.speed(speed))", speeds)

        if !s.voiceID.isEmpty { recentVoices.removeAll { $0 == s.voiceID }; recentVoices.insert(s.voiceID, at: 0) }
        let fill = VoiceGroups.groups(model.voices).flatMap(\.voices).map(\.id)
        let shown = Array((recentVoices + fill).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(6))
        let voices = NSMenu()
        for id in shown { add(VoiceGroups.name(id, in: model.voices), on: id == s.voiceID, to: voices) { [model] in model.setVoice(id) } }
        voices.addItem(.separator())
        add("More voices…", to: voices) { [openMain] in WindowRouter.shared.pane = .voices; openMain() }
        submenu("Voice  \(VoiceGroups.name(s.voiceID, in: model.voices))", voices)

        add("Show mini player", on: s.showMiniPlayer) { [model] in
            model.settings.showMiniPlayer.toggle()
            model.settings.showMiniPlayer ? MiniPlayer.shared.show() : MiniPlayer.shared.hide()
        }
        menu.addItem(.separator())

        let dictating = { if case .recording = model.dictation.state { true } else { false } }()
        add(dictating ? "Stop dictation" : "Dictate", s.dictationToggleShortcut) { [model] in
            if dictating { try? model.dictation.stop(insert: true, caller: "user") } else { try? model.dictation.start(caller: "user") }
        }
        add("Paste last transcript", s.pasteLastShortcut, enabled: !model.dictation.history.isEmpty) { [model] in model.dictation.pasteLast() }
        menu.addItem(.separator())

        add("Open Talk and Read…", action: openMain)
        add("Settings…", key: ",", action: openSettings)
        if model.needsSetup { add("⚠︎ Finish setup…", action: openOnboarding) }
        menu.addItem(.separator())
        add("Quit Talk and Read", key: "q") { NSApp.terminate(nil) }
    }

    // MARK: Building items

    private func add(_ title: String, _ shortcut: Settings.Shortcut? = nil, key: String = "", enabled: Bool = true, on: Bool = false,
                     to target: NSMenu? = nil, action: @escaping () -> Void) {
        let item = ActionItem(title: title, action: action)
        if let shortcut, let (k, mods) = Self.keyEquivalent(shortcut) {
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = mods
        } else if !key.isEmpty {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = .command
        }
        item.isEnabled = enabled
        item.state = on ? .on : .off
        (target ?? menu).addItem(item)
    }

    private func submenu(_ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    /// Display-only key equivalent for a global shortcut ("⌃⌥R" → "r" with ⌃⌥); nil for keys NSMenu can't show simply.
    static func keyEquivalent(_ s: Settings.Shortcut) -> (String, NSEvent.ModifierFlags)? {
        let key = String(s.display.drop { "⌃⌥⇧⌘".contains($0) })
        let mapped = key == "Space" ? " " : key
        guard !s.display.isEmpty, mapped.count == 1 else { return nil }
        return (mapped.lowercased(), NSEvent.ModifierFlags(rawValue: UInt(s.modifiers)).intersection([.control, .option, .shift, .command]))
    }

    /// One menu-item listing for the snapshot self-test.
    func dump(_ m: NSMenu? = nil, indent: String = "") -> [String] {
        (m ?? menu).items.flatMap { item -> [String] in
            if item.isSeparatorItem { return ["\(indent)----"] }
            var mods = ""
            let mask = item.keyEquivalentModifierMask
            if !item.keyEquivalent.isEmpty {
                if mask.contains(.control) { mods += "⌃" }
                if mask.contains(.option) { mods += "⌥" }
                if mask.contains(.shift) { mods += "⇧" }
                if mask.contains(.command) { mods += "⌘" }
            }
            let line = "\(indent)\(item.state == .on ? "✓ " : "")\(item.title)\(item.keyEquivalent.isEmpty ? "" : "   \(mods)\(item.keyEquivalent.uppercased())")\(item.isEnabled ? "" : "   (disabled)")"
            return [line] + (item.submenu.map { dump($0, indent: indent + "    ") } ?? [])
        }
    }
}

/// NSMenuItem that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}
