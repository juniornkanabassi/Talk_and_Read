// Entry point and app lifecycle: headless --selftest-* switches, menu bar item, windows and Dock icon, hotkeys,
// permission polling, login item, control server, sleep. Owned by WP7.
import AppKit
import Combine
import ServiceManagement
import Sparkle
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
        if let dir = value(after: "--selftest-asr") { exitAfter { await DictationSelfTest.run(dir: dir) } }
        if args.contains("--selftest-window") { exit(SelfTestWindow.run()) }
        if let dir = value(after: "--selftest-import") { exitAfter { await Importer.selfTest(directory: dir) } }
        if args.contains("--selftest-ui-snapshots") { exit(MainActor.assumeIsolated { UISnapshots.run() }) }
        if args.contains("--selftest-control") { exitAfter { await ControlSelfTest.run(clip: value(after: "--selftest-control")) } }
        if let feed = value(after: "--selftest-update") { exitAfter { await UpdateSelfTest.run(feed: feed) } }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Runs `work` headless and exits with its code. A main run loop, not dispatchMain: dispatchMain retires the main
    /// thread, so main-actor AppKit work would land on a worker thread (WP5's finding). The port keeps CFRunLoopRun
    /// from returning, and the loop from spinning, while nothing else is scheduled.
    private static func exitAfter(_ work: @escaping () async -> Int32) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no activation (a test may still relax it)
        Task { exit(await work()) }
        RunLoop.main.add(Port(), forMode: .default)
        while true { CFRunLoopRun() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var statusMenu: MenuBarMenu?
    private var showsSetupDot: Bool?
    private var hotkeys: Hotkeys?
    private var controlServer: ControlServer?
    /// Main, settings and onboarding windows; the Dock icon shows only while one is open.
    private var windows: [String: NSWindow] = [:]
    private var pollTimer: Timer?
    private var lastSettings: TalkReadCore.Settings?
    private var watchers: Set<AnyCancellable> = []
    /// S3: the speed and skip keys act, and are swallowed, only while a read is playing or paused; Esc only while recording.
    private var reading = false { didSet { hotkeys?.reading = reading } }
    private var recording = false { didSet { hotkeys?.recording = recording } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle: checks on launch and daily (Info.plist); installs only after the user agrees in its window.
        Updates.controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        NSApp.mainMenu = Self.mainMenu()
        let menu = MenuBarMenu(model: model, openMain: { [weak self] in self?.show("main") },
                               openSettings: { [weak self] in self?.show("settings") },
                               openOnboarding: { [weak self] in self?.show("onboarding") })
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.setAccessibilityLabel("Talk & Read")
        item.menu = menu.menu
        statusItem = item
        statusMenu = menu
        updateStatusIcon()
        MiniPlayer.shared.attach(model)
        WindowRouter.shared.showMainWindow = { [weak self] in self?.show("main") }
        WindowRouter.shared.openOnboarding = { [weak self] in self?.show("onboarding") }
        Task {
            await model.loadVoices()
            model.warmUp()
            do { controlServer = try ControlServer(path: Paths.controlSocket) { await AppModel.shared.handle($0) } } catch {
                Log.write("control socket unavailable: \(error)")
            }
        }

        model.$settings.sink { [weak self] in self?.settingsChanged($0) }.store(in: &watchers)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateStatusIcon() }.store(in: &watchers)
        model.$hotkeysPaused.sink { [weak self] in self?.hotkeys?.paused = $0 }.store(in: &watchers)
        model.$session
            .map { $0?.$state.map { $0 == .playing || $0 == .paused }.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher() }
            .switchToLatest().removeDuplicates()
            .sink { [weak self] in self?.reading = $0 }.store(in: &watchers)
        model.dictation.$state.map { if case .recording = $0 { true } else { false } }.removeDuplicates()
            .sink { [weak self] in self?.recording = $0 }.store(in: &watchers)
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

    /// Sol #4, #20: a quit during a copy or paste closes the pasteboard gate (queued pastes change nothing) and waits
    /// until the user's clipboard is back; a hung transaction is force-restored after 3 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await PasteboardGate.shared.shutdown(grace: 3)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopReading()
        AXWake.restoreAll()   // E8: also a capture superseded before its Highlighter existed
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
        // Reloading recreates the event tap, so only shortcut changes do it (not every speed-slider step).
        if Self.keys(s) != Self.keys(old) || s.dictationHoldKey != old.dictationHoldKey { hotkeys?.reload(s) }
        if s.launchAtLogin != old.launchAtLogin { updateLoginItem(s.launchAtLogin) }
    }

    private static func keys(_ s: TalkReadCore.Settings) -> [TalkReadCore.Settings.Shortcut] {
        TalkReadCore.Settings.chords.map { s[keyPath: $0.path] }
    }

    /// Only the installed copy registers as a login item; builds and test runs never touch it.
    private func updateLoginItem(_ on: Bool) {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/JuniorOS Apps/") else { return }
        let service = SMAppService.mainApp
        let path = Bundle.main.bundleURL.path, key = "loginItemRegisteredPath"
        do {
            for step in Self.loginItemSteps(on: on, status: service.status, recordedPath: UserDefaults.standard.string(forKey: key), path: path) {
                switch step {
                case .unregister: try service.unregister()
                case .register: try service.register()
                case .record: UserDefaults.standard.set(path, forKey: key)   // only after the steps before it succeeded
                }
            }
        } catch {
            Log.write("login item \(on ? "register" : "unregister") failed: \(error)")
        }
    }

    enum LoginItemStep: Equatable { case unregister, register, record }

    /// What `updateLoginItem` does, in order (pure; checked by the control self-test). `.requiresApproval` is a
    /// registration awaiting the user's approval, so it counts as registered (Sol 0.5.0 #5): off unregisters it; on keeps
    /// a registration for this path as it is (never registering twice); a registration from another path (0.5.0 renamed
    /// the bundle) or of unknown path is dropped and made again here, and the path is recorded after that succeeded.
    nonisolated static func loginItemSteps(on: Bool, status: SMAppService.Status, recordedPath: String?, path: String) -> [LoginItemStep] {
        let registered = status == .enabled || status == .requiresApproval
        guard on else { return registered ? [.unregister] : [] }
        if registered, recordedPath == path { return [] }
        return (registered ? [.unregister] : []) + [.register, .record]
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
            let keys = Hotkeys(settings: model.settings) { [weak self] in self?.perform($0) }
            keys.paused = model.hotkeysPaused
            keys.reading = reading
            keys.recording = recording
            keys.start()
            hotkeys = keys
        }
        if hotkeys != nil, windows.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .read: model.readSelection()
        case .pause: model.togglePause()
        case .screenshot: model.readScreenshot()
        // The current read only (S4); without one the key was not swallowed and typed its character.
        case .increaseSpeed, .decreaseSpeed: if reading { model.stepSpeed(action == .increaseSpeed ? 0.05 : -0.05) }
        case .skipBackward, .skipForward: if reading { model.skip(action == .skipForward ? 1 : -1) }
        default: model.dictation.handle(action)   // caller "user": the human always wins
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
        image.accessibilityDescription = dot ? "Talk & Read, setup incomplete" : "Talk & Read"
        button.image = image
    }

    // MARK: Windows

    @objc func openSettings(_ sender: Any?) { show("settings") }

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
        case "onboarding":
            let done: () -> Void = { [weak self] in self?.windows["onboarding"]?.close() }
            (title, view, size) = ("Welcome to Talk & Read", AnyView(OnboardingView(model: model, onFinish: done)), NSSize(width: 600, height: 540))
        case "settings":
            (title, view, size) = ("Settings", AnyView(SettingsView(model: model)), NSSize(width: 720, height: 520))
        default:
            (title, view, size) = ("Talk & Read", AnyView(MainWindowView(model: model)), NSSize(width: 980, height: 680))
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
        let update = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), "")
        update.target = Updates.controller   // Sparkle enables it only while a check can start
        add("Talk & Read", [item("About Talk & Read", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), update, .separator(),
                              item("Settings…", #selector(AppDelegate.openSettings(_:)), ","), .separator(),
                              item("Hide Talk & Read", #selector(NSApplication.hide(_:)), "h"),
                              item("Quit Talk & Read", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"), item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }
}
