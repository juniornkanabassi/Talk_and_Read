// Entry point and app lifecycle: headless --selftest-* switches, menu bar item, windows and Dock icon, hotkeys,
// permission polling, login item, control server, sleep. Owned by WP7.
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TalkReadCore

@main
enum TalkReadMain {
    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return args[i + 1]
        }
        // Headless switches run, report and exit; they never show a status item, start hotkeys or register a login item.
        if let file = value(after: "--selftest-tts") { exitAfter { await SelfTest.tts(file: file) } }
        if let dir = value(after: "--selftest-asr") { exitAfter { await SelfTest.asr(directory: dir) } }
        if args.contains("--selftest-window") { exit(SelfTestWindow.run()) }
        if args.contains("--selftest-control") { exitAfter { await ControlSelfTest.run(clip: value(after: "--selftest-control")) } }
        // --selftest-import and --selftest-ui-snapshots dispatch to WP6's static functions once WP6 is merged.

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func exitAfter(_ work: @escaping () async -> Int32) -> Never {
        Task { exit(await work()) }
        dispatchMain()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var showsSetupDot: Bool?
    private var hotkeys: Hotkeys?
    private var controlServer: ControlServer?
    /// Main, settings and onboarding windows; the Dock icon shows only while one is open.
    private var windows: [String: NSWindow] = [:]
    private var miniPlayer: NSPanel?
    private var miniPlayerWatch: AnyCancellable?
    private var pollTimer: Timer?
    private var lastSettings: TalkReadCore.Settings?
    private var watchers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.setAccessibilityLabel("Talk and Read")
        item.menu = statusMenu()
        statusItem = item
        updateStatusIcon()
        model.showMainWindow = { [weak self] in self?.show("main") }
        Task {
            await model.loadVoices()
            do { controlServer = try ControlServer(path: Paths.controlSocket) { await AppModel.shared.handle($0) } } catch {
                Log.write("control socket unavailable: \(error)")
            }
        }

        model.$settings.sink { [weak self] in self?.settingsChanged($0) }.store(in: &watchers)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateStatusIcon() }.store(in: &watchers)
        model.$session.compactMap { $0 }.sink { [weak self] in self?.showMiniPlayer($0) }.store(in: &watchers)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.pauseForSleep() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshPermissions() }
        }
        updateLoginItem(model.settings.launchAtLogin)
        startPolling()
        if !model.settings.onboardingDone { show("onboarding") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopReading()
        model.saveSettings()
        controlServer?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show("main") }
        return true
    }

    // MARK: Settings side effects

    private func settingsChanged(_ s: TalkReadCore.Settings) {
        defer { lastSettings = s }
        guard let old = lastSettings else { return }
        if Self.keys(s) != Self.keys(old) || s.dictationHoldKey != old.dictationHoldKey { hotkeys?.reload(s) }
        if s.launchAtLogin != old.launchAtLogin { updateLoginItem(s.launchAtLogin) }
        if s.onboardingDone, !old.onboardingDone { windows["onboarding"]?.close() }
    }

    private static func keys(_ s: TalkReadCore.Settings) -> [TalkReadCore.Settings.Shortcut] {
        [s.readShortcut, s.pauseShortcut, s.screenshotShortcut, s.dictationToggleShortcut, s.pasteLastShortcut]
    }

    /// Only the installed copy registers as a login item; builds and test runs never touch it.
    private func updateLoginItem(_ on: Bool) {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/JuniorOS Apps/") else { return }
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled { try service.register() }
            if !on, service.status == .enabled { try service.unregister() }
        } catch {
            Log.write("login item \(on ? "register" : "unregister") failed: \(error)")
        }
    }

    // MARK: Permissions and hotkeys

    /// Every 2 s until Accessibility is granted (then the hotkeys start) and while a window is open (live permission
    /// ticks); otherwise permissions refresh on app activation. Never prompts.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func poll() {
        model.refreshPermissions()
        if hotkeys == nil, model.permissions.accessibility {
            let keys = Hotkeys(onAction: { [weak self] in self?.perform($0) })
            keys.start(settings: model.settings)
            hotkeys = keys
        }
        if hotkeys != nil, windows.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func perform(_ action: HotkeyAction) {
        let d = model.dictation
        switch action {
        case .read: model.readSelection()
        case .pause: model.togglePause()
        case .screenshot: model.readScreenshot()
        case .startRecording: try? d.start(caller: "user")
        case .stopAndInsert: try? d.stop(insert: true, caller: "user")
        case .cancelRecording: try? d.cancel(caller: "user")
        case .toggleRecording:
            if case .recording = d.state { try? d.stop(insert: true, caller: "user") } else { try? d.start(caller: "user") }
        case .pasteLast: d.pasteLast()
        }
    }

    // MARK: Status item

    private static let menuBarImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        if let url2x = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let data = try? Data(contentsOf: url2x), let rep = NSBitmapImageRep(data: data) {
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }()

    /// The template icon, with a small dot while setup is incomplete.
    private func updateStatusIcon() {
        let dot = model.needsSetup
        guard dot != showsSetupDot, let button = statusItem?.button else { return }
        showsSetupDot = dot
        guard let base = Self.menuBarImage else { button.title = dot ? "T&R •" : "T&R"; return }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            if dot { NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "Talk and Read, setup incomplete" : "Talk and Read"
        button.image = image
    }

    /// ponytail: a minimal menu until WP6's MenuBarMenu is attached here at merge. Its rows can reuse the
    /// openMainWindow:, openSettings: and openOnboarding: actions below with a nil target.
    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Read Selection", #selector(readSelection)), ("Pause or Resume", #selector(togglePause)),
                                ("Open Talk and Read…", #selector(openMainWindow(_:))), ("Settings…", #selector(openSettings(_:))),
                                ("Finish Setup…", #selector(openOnboarding(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Talk and Read", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func readSelection() { model.readSelection() }
    @objc private func togglePause() { model.togglePause() }
    @objc func openMainWindow(_ sender: Any?) { show("main") }
    @objc func openSettings(_ sender: Any?) { show("settings") }
    @objc func openOnboarding(_ sender: Any?) { show("onboarding") }

    // MARK: Windows

    /// Opening a window is always the user's own request, so the app comes forward with a Dock icon.
    private func show(_ kind: String) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func makeWindow(_ kind: String) -> NSWindow {
        let title: String, view: AnyView, size: NSSize
        switch kind {
        case "onboarding": (title, view, size) = ("Welcome to Talk and Read", AnyView(OnboardingView(model: model)), NSSize(width: 640, height: 520))
        case "settings": (title, view, size) = ("Settings", AnyView(SettingsView(model: model)), NSSize(width: 640, height: 520))
        default: (title, view, size) = ("Talk and Read", AnyView(MainWindowView(model: model)), NSSize(width: 980, height: 680))
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.setContentSize(size)
        if kind == "main" { window.contentMinSize = NSSize(width: 760, height: 520) }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TalkRead.\(kind)")
        return window
    }

    /// Closed windows are dropped (their views stop updating); the Dock icon goes with the last one.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        windows[kind] = nil
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// ponytail: a plain floating panel around WP6's MiniPlayerView until WP6's own panel is wired here at merge.
    private func showMiniPlayer(_ session: ReadSession) {
        guard model.settings.showMiniPlayer else { return }
        let panel = miniPlayer ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 92), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(model.settings.miniPlayerOrigin ?? NSPoint(x: screen.midX - 220, y: screen.minY + 80))
            }
            return p
        }()
        panel.contentView = NSHostingView(rootView: MiniPlayerView(session: session))
        panel.orderFrontRegardless()
        miniPlayer = panel
        miniPlayerWatch = session.$state.sink { [weak self] state in
            switch state {
            case .finished, .failed: break
            default: return
            }
            guard let self, model.settings.miniPlayerAutoHideSeconds > 0 else { return }
            let delay = model.settings.miniPlayerAutoHideSeconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                if let self, model.session === session, model.liveSession == nil { miniPlayer?.orderOut(nil) }
            }
        }
    }

    // MARK: Main menu (shown while a window is open; gives text fields Cut, Copy, Paste and ⌘, for Settings)

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        add("Talk and Read", [item("About Talk and Read", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), .separator(),
                              item("Settings…", #selector(AppDelegate.openSettings(_:)), ","), .separator(),
                              item("Hide Talk and Read", #selector(NSApplication.hide(_:)), "h"),
                              item("Quit Talk and Read", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"), item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }
}
