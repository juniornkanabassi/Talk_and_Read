// One listen-only CGEvent tap on its own thread for the dictation hold key and the chord shortcuts, feeding
// TalkReadCore's HotkeyState on the main thread (PLAN decision 8). Gated on Accessibility. Listen-only, so the app
// underneath also receives the keys (⌃⌥ letters type nothing in normal apps).
import AppKit
import ApplicationServices
import TalkReadCore

final class Hotkeys {
    /// Every action, on the main thread.
    var onAction: ((HotkeyAction) -> Void)?
    /// The tap exists and is enabled (for the permissions UI). Main thread.
    private(set) var isRunning = false
    /// No actions fire while true (the settings shortcut recorder is listening). Main thread.
    var paused = false { didSet { resetHold() } }

    // Main thread only.
    private var settings: Settings
    private var state = HotkeyState()

    // Tap thread only (set up before `start` returns).
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static let rightOptionKeyCode: UInt16 = 61, fnKeyCode: UInt16 = 63
    static let rightOptionDeviceBit: UInt64 = 0x40, leftOptionDeviceBit: UInt64 = 0x20   // NX_DEVICE[RL]ALTKEYMASK
    static let command: UInt64 = 1 << 20, option: UInt64 = 1 << 19, control: UInt64 = 1 << 18, shift: UInt64 = 1 << 17
    static let secondaryFn: UInt64 = 1 << 23

    init(settings: Settings, onAction: ((HotkeyAction) -> Void)? = nil) {
        self.settings = settings
        self.onAction = onAction
    }

    /// Starts the tap; false without Accessibility or when the tap cannot be created. Never prompts. The tap thread
    /// keeps this object alive until `stop()`.
    @discardableResult func start() -> Bool {
        if thread != nil { return isRunning }
        guard AXIsProcessTrusted() else { return false }
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let t = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            created = createTap()
            let health = Timer(timeInterval: 5, repeats: true) { [self] _ in checkHealth() }
            RunLoop.current.add(health, forMode: .common)
            ready.signal()
            CFRunLoopRun()                      // until stop()
            health.invalidate()
            removeTap()
        }
        t.name = "Talk and Read hotkeys"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        isRunning = created
        return created
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
        self.runLoop = nil
        thread = nil
        isRunning = false
    }

    func reload(_ settings: Settings) {
        self.settings = settings
        resetHold()
    }

    /// Forgets the hold key; a recording it started is cancelled first (nothing typed), even while paused (Sol #19).
    private func resetHold() {
        for action in state.reset() { onAction?(action) }
    }

    // MARK: Tap thread

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    /// Re-enable a tap the system switched off; recreate it if that fails. Also the 5 s health timer.
    private func checkHealth() {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        removeTap()
        let ok = AXIsProcessTrusted() && createTap()
        DispatchQueue.main.async { self.isRunning = ok }
    }

    fileprivate func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { checkHealth(); return }
        guard event.getIntegerValueField(.eventSourceUserData) != PasteboardGate.eventTag,   // our own ⌘V (the only key event we post)
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { self.process(type, keyCode: keyCode, flags: flags, at: time) }
    }

    // MARK: Main thread

    /// Internal, not private: the dictation self-test feeds raw key data here (nothing is posted to the system).
    func process(_ type: CGEventType, keyCode: UInt16, flags: UInt64, at time: Double) {
        guard !paused, let event = Self.keyEvent(type, keyCode: keyCode, flags: flags, settings: settings) else { return }
        emit(state.handle(event, at: time))
        if event == .holdKeyDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + HotkeyState.holdDelay) { [weak self] in
                guard let self else { return }
                emit(state.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func emit(_ actions: [HotkeyAction]) {
        guard !paused else { return }
        for action in actions { onAction?(action) }
    }

    /// Raw key data -> state-machine event (pure; checked by the dictation self-test).
    static func keyEvent(_ type: CGEventType, keyCode: UInt16, flags: UInt64, settings: Settings) -> KeyEvent? {
        let holdKeyCode: UInt16? = switch settings.dictationHoldKey {
        case .rightOption: rightOptionKeyCode
        case .fn: fnKeyCode
        case .off: nil
        }
        switch type {
        case .flagsChanged where keyCode == holdKeyCode:
            let down = settings.dictationHoldKey == .fn ? flags & secondaryFn != 0 : flags & rightOptionDeviceBit != 0
            guard down else { return .holdKeyUp }
            // Held together with another modifier it is part of a shortcut, not the dictation key.
            let others = command | control | shift | (settings.dictationHoldKey == .fn ? option : leftOptionDeviceBit)
            return flags & others == 0 ? .holdKeyDown : .otherKeyDown(keyCode: keyCode, modifiers: flags)
        case .flagsChanged:
            let mask: UInt64 = switch keyCode {
            case 54, 55: command
            case 56, 60: shift
            case 58, 61: option
            case 59, 62: control
            case 63: secondaryFn
            default: 0
            }
            return flags & mask != 0 ? .otherKeyDown(keyCode: keyCode, modifiers: flags) : nil   // modifier released
        case .keyDown:
            let chords: [(Settings.Shortcut, HotkeyAction)] = [
                (settings.readShortcut, .read), (settings.pauseShortcut, .pause), (settings.screenshotShortcut, .screenshot),
                (settings.dictationToggleShortcut, .toggleRecording), (settings.pasteLastShortcut, .pasteLast)]
            let mods = flags & (command | option | control | shift)
            // A shortcut turned off is stored as keyCode 0, modifiers 0, empty display: never match it (it would be "a").
            if let match = chords.first(where: { !$0.0.display.isEmpty && $0.0.modifiers != 0
                && $0.0.keyCode == keyCode && $0.0.modifiers == mods }) { return .chord(match.1) }
            return .otherKeyDown(keyCode: keyCode, modifiers: flags)
        default:
            return nil
        }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info { Unmanaged<Hotkeys>.fromOpaque(info).takeUnretainedValue().received(type, event) }
    return Unmanaged.passUnretained(event)
}
