// Read from here (1.0): the small play glyph beside the paragraph under the pointer, shown only while the reveal key
// (left Option by default) is held on its own. While shown it looks under the pointer at most ten times a second and
// moves to each paragraph the pointer reaches; it stays put while the pointer travels across the margin towards it.
// A click reads from that paragraph to the end of its page. The panel never takes focus, so the app being read stays
// frontmost and its cursor stays where it was. Nothing runs and no panel exists while the key is up.
// Hover mode (opt in, off by default) is Speechify's way: with no key, the glyph shows beside a paragraph of a web page
// (a browser, the Claude or Codex app) once the pointer has rested on it, and goes when the pointer leaves it. It only
// reads the pointer's position until it rests, and asks the app only once per resting place.
import AppKit
import ApplicationServices
import Combine
import TalkReadCore

@MainActor final class ReadHereGlyph {
    static let shared = ReadHereGlyph()
    static let size: CGFloat = 22
    static let gap: CGFloat = 6

    private weak var model: AppModel?
    private var state = RevealState()
    private var timer: Timer?
    private var panel: Panel?
    private(set) var block: PointerCapture.Block?
    private var lastPoint: CGPoint?
    private var looking = false
    /// Until when hover keeps asking about a still pointer: an app just asked to build its tree is still filling it in.
    private var hoverColdUntil = 0.0
    /// Until when a woken app's tree may still be filling in: a still pointer is looked at again each tick until then.
    private var coldUntil = 0.0
    /// Apps this reveal woke (E8); put back when the glyph hides, unless a read on them is running.
    private var woken = Set<pid_t>()
    private var hoverTimer: Timer?
    /// Where the pointer last stopped, since when, and whether that place was looked at.
    private var rest: (point: CGPoint, since: Double, looked: Bool)?
    /// Apps hover mode asked to build their tree (AXManualAccessibility: harmless, and it stays set).
    private var asked = Set<pid_t>()
    private var settingsWatch: AnyCancellable?
    private var spaceWatch: NSObjectProtocol?
    static let restDelay = 0.3

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func attach(_ model: AppModel) {
        self.model = model
        settingsWatch = model.$settings.map(\.readHereHover).removeDuplicates().sink { [weak self] in self?.setHover($0) }
        // Another Space shows other windows: a hover glyph would read a paragraph no longer on screen (the panel joins every Space).
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    // MARK: The reveal key

    /// Raw key data from the hotkey tap (main thread), with the shortcuts in force.
    func key(_ type: CGEventType, keyCode: UInt16, flags: UInt64, at time: Double, settings: Settings) {
        let event = Self.revealEvent(type, keyCode: keyCode, flags: flags, settings: settings)
        // Any key or modifier but the reveal key itself puts a hover glyph away, whatever the reveal key is set to.
        if timer == nil, block != nil, type == .keyDown || (type == .flagsChanged && event != .keyDown && event != .keyUp) { hidePanel(); block = nil }
        guard let event else { return }
        apply(state.handle(event, at: time))
        if event == .keyDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + RevealState.delay) { [weak self] in
                guard let self else { return }
                apply(state.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    func reset() {
        apply(state.reset())
        if timer == nil { hidePanel(); block = nil }   // a hover glyph has no held key for reset() to see
    }

    /// Raw key data -> reveal event (pure; checked by the dictation self-test). Fn only when dictation does not hold it.
    nonisolated static func revealEvent(_ type: CGEventType, keyCode: UInt16, flags: UInt64, settings: Settings) -> RevealEvent? {
        let key: (keyCode: UInt16, down: UInt64, others: UInt64)? = switch settings.readHereKey {
        case .leftOption: (58, Hotkeys.leftOptionDeviceBit,
                           Hotkeys.command | Hotkeys.control | Hotkeys.shift | Hotkeys.rightOptionDeviceBit | Hotkeys.secondaryFn)
        case .fn where settings.dictationHoldKey != .fn: (Hotkeys.fnKeyCode, Hotkeys.secondaryFn,
                                                          Hotkeys.command | Hotkeys.control | Hotkeys.shift | Hotkeys.option)
        default: nil
        }
        guard let key else { return nil }
        switch type {
        case .flagsChanged where keyCode == key.keyCode:
            guard flags & key.down != 0 else { return .keyUp }
            return flags & key.others == 0 ? .keyDown : .otherKey
        case .flagsChanged, .keyDown: return .otherKey
        default: return nil
        }
    }

    private func apply(_ actions: [RevealAction]) {
        for action in actions {
            switch action {
            case .show: start()
            case .hide: stop()
            }
        }
    }

    // MARK: Looking under the pointer

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
        look()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        hidePanel()
        (block, lastPoint) = (nil, nil)
        let reading = model?.liveSession?.capture?.pid
        for pid in woken where pid != reading { AXWake.restore(pid) }
        woken = []
    }

    private func look() {
        // A key-up the tap missed (it was switched off a moment) must not leave the glyph and this timer running.
        guard revealKeyIsDown() else { reset(); return }
        guard !looking, NSEvent.pressedMouseButtons == 0 else { return }   // an Option-drag or Option-click is no reveal
        let point = Self.pointer()
        if let block, moved(block) || hidden(block) { hidePanel(); (self.block, lastPoint) = (nil, nil) }   // scrolled or covered
        guard point != lastPoint else { return }
        lastPoint = point
        if let block, Self.band(block).contains(point) { return }   // on its way to the glyph, or still on the paragraph
        looking = true
        Task { @MainActor in
            defer { looking = false }
            guard let hit = PointerCapture.hit(point) else {   // our own window, or nothing (the glyph is inside the band)
                if timer != nil { hidePanel(); block = nil }
                return
            }
            var found = PointerCapture.block(from: hit.element, pid: hit.pid, point: point)
            if found == nil, !woken.contains(hit.pid) {
                woken.insert(hit.pid)
                coldUntil = ProcessInfo.processInfo.systemUptime + 1.5
                await AXWake.wake(AXUIElementCreateApplication(hit.pid), pid: hit.pid)
                guard timer != nil else {   // the key went up during the wake, after stop() put back what it knew of
                    if hit.pid != model?.liveSession?.capture?.pid { AXWake.restore(hit.pid) }
                    return
                }
                // A key-up and a fresh hold during the wake: that stop() cleared `woken` before the wake could ledger
                // this app, so this hold's stop() must be the one to put it back.
                woken.insert(hit.pid)
                if let again = PointerCapture.hit(point), again.pid == hit.pid {
                    found = PointerCapture.block(from: again.element, pid: again.pid, point: point)
                }
            }
            // A cold tree fills in over the next ticks: look here again while it may still be loading.
            if found == nil, ProcessInfo.processInfo.systemUptime < coldUntil { lastPoint = nil }
            guard timer != nil else { return }   // the key went up meanwhile
            if let found { show(found) } else if block.map({ !Self.band($0).contains(point) }) ?? true { hidePanel(); block = nil }
        }
    }

    /// Another window or dialog, even the same app's, shows at `point` on the paragraph instead of its own window.
    static func covered(_ block: PointerCapture.Block, at point: CGPoint) -> Bool {
        guard let under = PointerCapture.hit(point), under.pid == block.pid else { return true }
        return !PointerCapture.bounded {
            guard let a = axElement(under.element, kAXWindowAttribute), let b = axElement(block.element, kAXWindowAttribute) else { return true }
            return CFEqual(a, b)
        }
    }

    /// The paragraph is no longer what shows beside the glyph: covered by another window, checked on its first line
    /// clear of the glyph (our own panel answers no hit test). Too short to leave such a point: not checked here.
    private func hidden(_ block: PointerCapture.Block) -> Bool {
        let glyph = Self.glyphFrame(block)
        let x = max(block.frame.minX + min(8, block.frame.width / 2), glyph.maxX + 2)
        return x < block.frame.maxX - 1 && Self.covered(block, at: CGPoint(x: x, y: glyph.midY))
    }

    /// The paragraph's frame moved or changed size (a scroll, a reflow): the glyph no longer belongs where it is.
    private func moved(_ block: PointerCapture.Block) -> Bool {
        let now: CGRect? = PointerCapture.bounded {   // every tick: a hung app must not freeze it
            if let start = block.start { axBounds(block.element, location: start, length: block.length) } else { axFrame(block.element) }
        }
        guard let now else { return true }   // gone from the page
        return abs(now.minX - block.frame.minX) > 1 || abs(now.minY - block.frame.minY) > 1   // scrolled
            || abs(now.width - block.frame.width) > 1 || abs(now.height - block.frame.height) > 1   // reflowed in place
    }

    /// The reveal key as the window server sees it now, for the case where its key-up never reached the tap. Either
    /// Option counts here: the tap already told the two apart when the glyph showed.
    private func revealKeyIsDown() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        switch model?.settings.readHereKey ?? .leftOption {
        case .leftOption: return flags & Hotkeys.option != 0
        case .fn: return flags & Hotkeys.secondaryFn != 0
        case .off: return false
        }
    }

    // MARK: Hover mode

    /// Held or hovering, the glyph's paragraph is on the Space just left: look again on this one.
    private func spaceChanged() {
        hidePanel()
        (block, rest, lastPoint) = (nil, nil, nil)
    }

    private func setHover(_ on: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        rest = nil
        if !on {
            if timer == nil { hidePanel(); block = nil }
            return
        }
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.hoverTick() } }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func hoverTick() {
        guard timer == nil, !looking else { return }   // the held key has the glyph
        let point = Self.pointer(), now = ProcessInfo.processInfo.systemUptime
        if let block, !Self.band(block).contains(point) || moved(block) || hidden(block) { hidePanel(); self.block = nil; rest = nil }   // left, scrolled or covered
        guard NSEvent.pressedMouseButtons == 0 else { rest = nil; return }   // a drag or a click in progress
        guard NSEvent.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty else { return }   // a shortcut on its way
        guard let r = rest, hypot(r.point.x - point.x, r.point.y - point.y) < 3 else {
            rest = (point, now, false)
            return
        }
        guard !r.looked, now - r.since >= Self.restDelay else { return }
        rest?.looked = true
        if let block, Self.band(block).contains(point) { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), let hit = PointerCapture.hit(point) else { return }
        if !asked.contains(hit.pid) {
            asked.insert(hit.pid)
            hoverColdUntil = now + 1.5
            _ = PointerCapture.bounded {   // unasked, on the main thread: a hung app answers within the short timeout
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(hit.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
        }
        // Web pages only: in native text views the glyph would follow every click and caret.
        guard let found = PointerCapture.block(from: hit.element, pid: hit.pid, point: point), found.start == nil else {
            if now < hoverColdUntil { rest?.looked = false }   // a cold tree: a fresh hit test on the next tick
            return
        }
        show(found)
    }

    /// Where the pointer may be and keep this glyph: the paragraph and the margin out to the glyph, in AX coordinates.
    static func band(_ block: PointerCapture.Block) -> CGRect {
        let left = glyphFrame(block).minX - 8
        return CGRect(x: left, y: block.frame.minY - 4, width: block.frame.maxX - left, height: block.frame.height + 8)
    }

    /// The glyph's frame in AX (top-left) coordinates: left of the paragraph, centred on its first line, kept on screen.
    static func glyphFrame(_ block: PointerCapture.Block) -> CGRect {
        let line = min(block.frame.height, 26)
        var x = block.frame.minX - size - gap
        var y = block.frame.minY + (line - size) / 2
        if let view = block.viewport, y < view.minY + 2 { y = min(view.minY + 2, block.frame.maxY - size) }   // first line scrolled away
        let screen = NSScreen.screens.map { Locator.convert(topLeftScreenRect: $0.frame) }.first { $0.contains(CGPoint(x: block.frame.minX, y: y)) }
        if let screen { x = max(screen.minX + 2, x) }
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The pointer in AX (top-left) coordinates.
    static func pointer() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    // MARK: The panel

    private func show(_ found: PointerCapture.Block) {
        block = found
        let frame = Locator.convert(topLeftScreenRect: Self.glyphFrame(found))
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let p = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let view = GlyphView(frame: NSRect(origin: .zero, size: frame.size))
        view.colour = NSColor(hex: model?.settings.highlightHex ?? Theme.accentHex) ?? Theme.accentNS
        view.onPress = { [weak self] in self?.play() }
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func play() {
        guard let block else { return }
        self.block = nil
        // Out of the panel's own mouseDown first: closing it there would release the window that is handling the click.
        // With the glyph gone, nothing of ours covers the paragraph, however short or close to the screen's edge it is.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hidePanel()
            guard !Self.covered(block, at: CGPoint(x: block.frame.minX + min(8, block.frame.width / 2), y: Self.glyphFrame(block).midY)) else { return }
            woken.remove(block.pid)   // the read's Highlighter puts the app back when it ends (E8)
            model?.readHere(block: block)
        }
    }

    /// A play triangle in a soft disc of the highlight colour; brighter under the pointer. Takes the first click, so
    /// the app underneath never sees it and Talk & Read never becomes active.
    final class GlyphView: NSView {
        var colour = Theme.accentNS
        var onPress: (() -> Void)?
        private var hovered = false { didSet { needsDisplay = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Read from here")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseDown(with event: NSEvent) { onPress?() }
        override func accessibilityPerformPress() -> Bool { onPress?(); return true }

        override func draw(_ dirtyRect: NSRect) {
            let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            colour.withAlphaComponent(hovered ? 1 : 0.8).setFill()
            disc.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            disc.lineWidth = 0.5
            disc.stroke()
            let s = bounds.width, t = NSBezierPath()
            t.move(to: NSPoint(x: s * 0.40, y: s * 0.30))
            t.line(to: NSPoint(x: s * 0.40, y: s * 0.70))
            t.line(to: NSPoint(x: s * 0.72, y: s * 0.50))
            t.close()
            NSColor(white: 0.12, alpha: 0.9).setFill()
            t.fill()
        }
    }
}
