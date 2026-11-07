// Entry point and app lifecycle: headless --selftest-* switches, menu bar item, windows and Dock icon, hotkeys,
// permission polling, login item, control server, sleep. Owned by WP7.
import AppKit
import ObjCExceptionCatch
import Combine
import ServiceManagement
import SwiftUI
import TalkReadCore

@main
enum TalkReadMain {
    static func main() {
        TRInstallInvisibleChecks()
        let args = CommandLine.arguments
        if invisibleChecks {
            guard let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"],
                  Self.isDisposableHome(home) else {
                fputs("Headless checks require TALKREAD_HOME inside a disposable temporary folder.\n", stderr)
                exit(2)
            }
        }
        if invisibleChecks {
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSWindow.keepEveryWindowInvisible()
        }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return args[i + 1]
        }
        // Headless switches run, report and exit; they never show a status item, start hotkeys or register a login item.
        if args.contains("--selftest-model-downloads") { exitAfter { await ModelDownloadSelfTest.run() } }
        if args.contains("--selftest-agent-safety") { exitAfter { await SelfTestInvisibleWindows.safety() } }
        if args.contains("--selftest-invisible-windows") { exit(MainActor.assumeIsolated { SelfTestInvisibleWindows.run() }) }
        if let file = value(after: "--selftest-asr-cold-start") { exitAfter { await DictationColdStartBench.run(file: file) } }
        if let file = value(after: "--selftest-tts") { exitAfter { await SelfTest.tts(file: file) } }
        if let dir = value(after: "--selftest-asr") { exitAfter { await DictationSelfTest.run(dir: dir) } }
        if args.contains("--selftest-window") { exit(SelfTestWindow.run()) }
        if let dir = value(after: "--selftest-import") { exitAfter { await Importer.selfTest(directory: dir) } }
        if args.contains("--selftest-ui-snapshots") { exit(MainActor.assumeIsolated { UISnapshots.run() }) }
        if args.contains("--selftest-ui-commands") { exit(MainActor.assumeIsolated { MenuSelfTest.run() }) }
        if args.contains("--selftest-reader-performance") { exitAfter { await ReaderPerformanceSelfTest.run() } }
        if args.contains("--selftest-storage") { exitAfter { await StorageSelfTest.run() } }
        if args.contains("--selftest-control") { exitAfter { await ControlSelfTest.run(clip: value(after: "--selftest-control")) } }
        if let feed = value(after: "--selftest-update") { exitAfter { await UpdateSelfTest.run(feed: feed, args: args) } }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(invisibleChecks ? .prohibited : .accessory)
        app.run()
    }

    static var invisibleChecks: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || CommandLine.arguments.contains { $0 == "--agent-screen" || $0.hasPrefix("--selftest-") }
    }

    static func isDisposableHome(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/tmp", "/private/tmp", FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path]
        return roots.contains { resolved.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var statusMenu: MenuBarMenu?
    private var iconLabel: String?
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
    private var openSettingsScene: (() -> Void)?
    private var settingsCloseObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !TalkReadMain.invisibleChecks else { return }
        let scenes = NSHostingSceneRepresentation {
            SwiftUI.Settings {
                SettingsView(model: model)
                    .background(SettingsWindowRegistration { [weak self] window in
                        self?.registerSettingsWindow(window)
                    })
            }
        }
        NSApp.addSceneRepresentation(scenes)
        openSettingsScene = { scenes.environment.openSettings() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if TalkReadMain.invisibleChecks {
            // Agent copies expose only their disposable control socket, never global shortcuts or launch side effects.
            Task {
                await model.loadVoices()
                do { controlServer = try ControlServer(path: Paths.controlSocket) { await AppModel.shared.handle($0) } }
                catch { Log.write("control socket unavailable: \(error)") }
            }
            return
        }
        // Sparkle: checks at launch and daily; installs only after the user agrees in its window. Off without SUFeedURL.
        Updates.shared.start()
        NSApp.mainMenu = Self.mainMenu(delegate: self)
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
        ReadHereGlyph.shared.attach(model)
        WindowRouter.shared.showMainWindow = { [weak self] in self?.show("main") }
        WindowRouter.shared.openOnboarding = { [weak self] in self?.show("onboarding") }
        WindowRouter.shared.openSettings = { [weak self] tab in
            WindowRouter.shared.settingsTab = tab
            self?.show("settings")
        }
        Task {
            await model.loadVoices()
            model.warmUp()
            do { controlServer = try ControlServer(path: Paths.controlSocket) { await AppModel.shared.handle($0) } } catch {
                Log.write("control socket unavailable: \(error)")
            }
        }

        model.$settings.sink { [weak self] in self?.settingsChanged($0) }.store(in: &watchers)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateStatusIcon() }.store(in: &watchers)
        Updates.shared.$reminder.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &watchers)
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.warmDictation() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshPermissions() }
        }
        updateLoginItem(model.settings.launchAtLogin)
        startPolling()
        // A start by the CLI or MCP (--headless) stays out of sight; onboarding waits for the next ordinary launch.
        if !model.settings.onboardingDone && !CommandLine.arguments.contains("--headless") { show("onboarding") }
    }

    /// Sol #4, #20: a quit during a copy or paste closes the pasteboard gate (queued pastes change nothing) and waits
    /// until the user's clipboard is back; a hung transaction is force-restored after 3 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controlServer?.stop()
        model.stopReading()
        Task {
            await PasteboardGate.shared.shutdown(grace: 3)
            await model.flushPersistence()
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
        if Self.keys(s) != Self.keys(old) || s.dictationHoldKey != old.dictationHoldKey || s.readHereKey != old.readHereKey { hotkeys?.reload(s) }
        if s.launchAtLogin != old.launchAtLogin { updateLoginItem(s.launchAtLogin) }
        if s.automaticUpdateChecks != old.automaticUpdateChecks { Updates.shared.updater?.automaticallyChecksForUpdates = s.automaticUpdateChecks }
    }

    private static func keys(_ s: TalkReadCore.Settings) -> [TalkReadCore.Settings.Shortcut] {
        TalkReadCore.Settings.chords.map { s[keyPath: $0.path] }
    }

    /// Only an installed copy registers as a login item; builds and test runs never touch it.
    private func updateLoginItem(_ on: Bool) {
        guard !TalkReadMain.invisibleChecks, Self.isInstalledCopy(Bundle.main.bundleURL.path) else { return }
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

    /// In /Applications (any folder in it, Junior's "JuniorOS Apps" too) or ~/Applications: where a downloaded copy is
    /// dragged. Not a build, a test install under /private/tmp, or a copy run from Downloads (macOS translocates it).
    /// Until 0.7.0 only "JuniorOS Apps" counted, so "Open at login" did nothing on any other Mac (0.7.1).
    nonisolated static func isInstalledCopy(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

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
        guard !TalkReadMain.invisibleChecks, pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func poll() {
        guard !TalkReadMain.invisibleChecks else { return }
        model.refreshPermissions()
        if hotkeys == nil, model.permissions.accessibility {
            let keys = Hotkeys(settings: model.settings) { [weak self] in self?.perform($0) }
            let glyph = ReadHereGlyph.shared
            keys.onKey = { glyph.key($0, keyCode: $1, flags: $2, at: $3, settings: $4) }
            keys.onReset = { glyph.reset() }
            keys.paused = model.hotkeysPaused
            keys.reading = reading
            keys.recording = recording
            keys.start()
            hotkeys = keys
        }
        if hotkeys != nil, !windows.values.contains(where: Self.windowIsOpen) {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .read: model.readSelection()
        case .readHere: model.readHere()
        case .pause: model.togglePause()
        case .screenshot: model.readScreenshot()
        // The current read only (S4); without one the key was not swallowed and typed its character.
        case .increaseSpeed, .decreaseSpeed: if reading { model.stepSpeed(up: action == .increaseSpeed) }
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

    /// The template icon, with a small dot while setup is incomplete or an update found in the background waits.
    private func updateStatusIcon() {
        let label = model.needsSetup ? "Talk & Read, setup incomplete" : Updates.shared.reminder != nil ? "Talk & Read, update available" : "Talk & Read"
        guard label != iconLabel, let button = statusItem?.button else { return }
        iconLabel = label
        let dot = label != "Talk & Read"
        guard let base = Self.menuBarImage else { button.title = dot ? "T&R •" : "T&R"; return }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            if dot { NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        button.image = image
    }

    // MARK: Windows

    @objc func openSettings(_ sender: Any?) { show("settings") }

    /// Opening a window is always the user's own request, so the app comes forward with a Dock icon.
    private func show(_ kind: String) {
        if kind == "settings" {
            NSApp.setActivationPolicy(TalkReadMain.invisibleChecks ? .prohibited : .regular)
            openSettingsScene?()
            NSApp.activate()
            startPolling()
            return
        }
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        NSApp.setActivationPolicy(TalkReadMain.invisibleChecks ? .prohibited : .regular)
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

    /// SwiftUI keeps its own delegate; only observe the lifecycle event we need.
    func registerSettingsWindow(_ window: NSWindow) {
        if let settingsCloseObserver { NotificationCenter.default.removeObserver(settingsCloseObserver) }
        windows["settings"] = window
        settingsCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                        object: window, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.windowWillClose(note) }
        }
    }

    static func windowIsOpen(_ window: NSWindow) -> Bool { window.isVisible || window.isMiniaturized }

    /// Closed windows are dropped (their views stop updating); the Dock icon goes with the last one.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        // SwiftUI owns its Settings window and can reuse it when opened again.
        if kind != "settings" { windows[kind] = nil }
        if !windows.values.contains(where: { $0 !== window && Self.windowIsOpen($0) }) { NSApp.setActivationPolicy(TalkReadMain.invisibleChecks ? .prohibited : .accessory) }
    }

}

private struct SettingsWindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(register: register) }
    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        let register: (NSWindow) -> Void
        init(register: @escaping (NSWindow) -> Void) {
            self.register = register
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register(window) }
        }
    }
}


extension NSWindow {
    /// Keep later AppKit updates transparent too, as in Video Prompter's --agent-screen checks.
    static func keepEveryWindowInvisible() {
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.alphaValue != 0 || !window.ignoresMouseEvents else { return }
            MainActor.assumeIsolated { window.alphaValue = 0; window.ignoresMouseEvents = true }
        }
    }
}

@MainActor private enum SelfTestInvisibleWindows {
    static func safety() async -> Int32 {
        guard TalkReadMain.invisibleChecks else { return 1 }
        guard TRInvisibleChecksSilencesResponder() else {
            print("FAIL agent safety: silent responder guard is not installed")
            return 1
        }
        var refreshes = 0
        for permission: PermissionKind in [.accessibility, .microphone, .screenRecording] {
            PermissionRequests.request(permission) { refreshes += 1 }
        }
        guard refreshes == 3 else { return 1 }
        let recorder = Recorder()
        do { try await recorder.start(); return 1 }
        catch RecorderError.noPermission {} catch { return 1 }
        do { try recorder.openInput(session: 1); return 1 } catch {}
        guard recorder.stop().isEmpty else { return 1 }
        let hardware = Player()
        hardware.volume = 1
        guard hardware.volume == 0 else { return 1 }
        let offline = Player(manualRendering: true)
        offline.volume = 1
        guard offline.volume == 1 else { return 1 }
        print("PASS agent safety: permission actions suppressed, real microphone blocked, hardware output muted, offline PCM preserved")
        return 0
    }

    static func run() -> Int32 {
        guard TRInvisibleChecksSilencesResponder() else {
            print("FAIL invisible windows: silent responder guard is not installed")
            return 1
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for show in [{ window.makeKeyAndOrderFront(nil) }, { window.orderFrontRegardless() }, { window.orderFront(nil) }] {
            window.alphaValue = 1
            show()
            guard window.isVisible, window.alphaValue == 0, window.ignoresMouseEvents else { return 1 }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            window.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        guard !NSApp.isActive else { return 1 }
        print("PASS invisible windows: all ordering paths transparent and click-through, activation blocked")
        return 0
    }
}
