// One active CGEvent tap on its own thread for the dictation hold key and the chord shortcuts, feeding TalkReadCore's
// HotkeyState on the main thread (PLAN decision 8). Gated on Accessibility. Active (S3): a matched shortcut is
// swallowed on the tap thread (KeyConsumer decides from a locked snapshot), so ⌃A never reaches the app underneath.
import AppKit
import ApplicationServices
import os
import TalkReadCore

final class Hotkeys {
    /// Every action, on the main thread.
    var onAction: ((HotkeyAction) -> Void)?
    /// Every key-down and modifier change while not paused, with the shortcuts in force, on the main thread: the Read
    /// from here glyph watches its reveal key here. `onReset` when the hold is forgotten (paused, reloaded).
    var onKey: ((CGEventType, UInt16, UInt64, Double, Settings) -> Void)?
    var onReset: (() -> Void)?
    /// The tap exists and is enabled (for the permissions UI). Main thread.
    private(set) var isRunning = false
    /// No actions fire and nothing is swallowed while true (the settings shortcut recorder is listening). Main thread.
    var paused = false { didSet { context.withLock { $0.paused = paused }; resetHold() } }
    /// A read is playing or paused / dictation is recording: the speed and skip keys, and Esc, are swallowed only then. Main thread.
    var reading = false { didSet { context.withLock { $0.reading = reading } } }
    var recording = false { didSet { context.withLock { $0.recording = recording } } }

    // Main thread only.
    private var settings: Settings
    private var state = HotkeyState()

    /// What the tap thread decides with; written on the main thread, read on the tap thread.
    private let context: OSAllocatedUnfairLock<KeyConsumer.Context>

    // Tap thread only (set up before `start` returns).
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumer = KeyConsumer()

    static let rightOptionKeyCode: UInt16 = 61, fnKeyCode: UInt16 = 63, rightCommandKeyCode: UInt16 = 54
    static let rightOptionDeviceBit: UInt64 = 0x40, leftOptionDeviceBit: UInt64 = 0x20   // NX_DEVICE[RL]ALTKEYMASK
    static let rightCommandDeviceBit: UInt64 = 0x10, leftCommandDeviceBit: UInt64 = 0x08 // NX_DEVICE[RL]CMDKEYMASK
    static let command: UInt64 = 1 << 20, option: UInt64 = 1 << 19, control: UInt64 = 1 << 18, shift: UInt64 = 1 << 17
    static let secondaryFn: UInt64 = 1 << 23

    init(settings: Settings, onAction: ((HotkeyAction) -> Void)? = nil) {
        self.settings = settings
        self.onAction = onAction
        context = OSAllocatedUnfairLock(initialState: KeyConsumer.Context(settings: settings))
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
        t.name = "Talk & Read hotkeys"
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
        context.withLock { $0.settings = settings }
        resetHold()
    }

    /// Forgets the hold key; a recording it started is cancelled first (nothing typed), even while paused (Sol #19).
    private func resetHold() {
        for action in state.reset() { onAction?(action) }
        onReset?()
    }

    // MARK: Tap thread

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
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
        consumer.reset()   // key-ups missed while the tap was off must not leave a key swallowed
        DispatchQueue.main.async { self.onReset?() }   // nor a reveal it never saw end: the glyph starts again from the key
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        removeTap()
        let ok = AXIsProcessTrusted() && createTap()
        DispatchQueue.main.async { self.isRunning = ok }
    }

    /// True = swallow the event. Decided here, synchronously and quickly (a slow callback gets the tap switched off);
    /// the action itself runs on the main thread.
    fileprivate func received(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { consumer.reset(); checkHealth(); return false }
        let ours = event.getIntegerValueField(.eventSourceUserData) == PasteboardGate.eventTag   // our own ⌘V (the only key event we post)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let kind: KeyConsumer.Event = switch type {
        case .keyUp: .up
        case .flagsChanged: .flagsChanged
        default: isRepeat ? .autoRepeat : .down
        }
        let swallow = consumer.swallow(kind, keyCode: keyCode, modifiers: flags, ours: ours, in: context.withLock { $0 })
        if !ours, kind == .down || kind == .flagsChanged {
            let time = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { self.process(type, keyCode: keyCode, flags: flags, at: time) }
        }
        return swallow
    }

    /// True when this process has an enabled active tap (`.defaultTap`, able to swallow events); for the self-test.
    static func ownTapIsActive() -> Bool {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return false }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return false }
        return taps.prefix(Int(count)).contains { $0.tappingProcess == getpid() && $0.options == .defaultTap && $0.enabled }
    }

    // MARK: Main thread

    /// Internal, not private: the dictation self-test feeds raw key data here (nothing is posted to the system).
    func process(_ type: CGEventType, keyCode: UInt16, flags: UInt64, at time: Double) {
        guard !paused else { return }
        onKey?(type, keyCode, flags, time, settings)
        guard let event = Self.keyEvent(type, keyCode: keyCode, flags: flags, settings: settings) else { return }
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
        // The hold key's code, the flag that says it is down, and the modifiers that make it part of a shortcut instead.
        let hold: (keyCode: UInt16, down: UInt64, others: UInt64)? = switch settings.dictationHoldKey {
        case .rightOption: (rightOptionKeyCode, rightOptionDeviceBit, command | control | shift | leftOptionDeviceBit)
        case .fn: (fnKeyCode, secondaryFn, command | control | shift | option)
        case .rightCommand: (rightCommandKeyCode, rightCommandDeviceBit, option | control | shift | leftCommandDeviceBit)
        case .off: nil
        }
        switch type {
        case .flagsChanged where keyCode == hold?.keyCode:
            guard let hold, flags & hold.down != 0 else { return .holdKeyUp }
            return flags & hold.others == 0 ? .holdKeyDown : .otherKeyDown(keyCode: keyCode, modifiers: flags)
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
            if let action = settings.action(keyCode: keyCode, modifiers: flags) { return .chord(action) }
            return .otherKeyDown(keyCode: keyCode, modifiers: flags)
        default:
            return nil
        }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info, Unmanaged<Hotkeys>.fromOpaque(info).takeUnretainedValue().received(type, event) { return nil }
    return Unmanaged.passUnretained(event)
}
