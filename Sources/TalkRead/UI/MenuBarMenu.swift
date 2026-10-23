// The status item's menu, rebuilt each time it opens. The lead attaches `menu` to the NSStatusItem. Owned by WP6.
import AppKit
import TalkReadCore

@MainActor final class MenuBarMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model: AppModel
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private let openOnboarding: () -> Void

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

        let speed = Double(model.activeSpeed)   // a 1x preview shows 1x
        let speeds = NSMenu()
        for p in Theme.quickSpeeds { add(Theme.speed(p), on: abs(p - speed) < 0.001, to: speeds) { [model] in model.setSpeed(Float(p)) } }
        submenu("Speed  \(Theme.speed(speed))", speeds)

        submenu("Voice  \(VoiceGroups.name(s.voiceID, in: model.voices))", voiceMenu(model.voices, english: s.voiceID, french: s.frenchVoiceID))

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

    /// Female voices grouped by model (V5), then the French voices; ticks on the English and the French voice.
    func voiceMenu(_ voices: [Voice], english: String, french: String) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        func list(_ v: Voice, _ title: String, on: Bool) { add(title, on: on, to: sub) { [model] in model.setVoice(v.id) } }
        for group in VoiceGroups.byModel(voices, language: "en") {
            sub.addItem(.sectionHeader(title: group.model.modelName))
            for v in group.voices { list(v, VoiceGroups.label(v), on: v.id == english) }
        }
        let frenchGroups = VoiceGroups.byModel(voices, language: "fr")
        if !frenchGroups.isEmpty {
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: "French"))
            for g in frenchGroups { for v in g.voices { list(v, "\(v.name) (\(g.model.modelName))", on: v.id == french) } }
        }
        sub.addItem(.separator())
        add("More voices…", to: sub) { [openMain] in WindowRouter.shared.pane = .voices; openMain() }
        return sub
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
            if item.isSectionHeader { return ["\(indent)[\(item.title)]"] }
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
