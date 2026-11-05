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
    private var generation = 0
    private var clickGeneration = 0
    private var wakeLeases = WakeLeases()
    /// Until when hover keeps asking about a still pointer: an app just asked to build its tree is still filling it in.
    private var hoverColdUntil = 0.0
    /// Until when a woken app's tree may still be filling in: a still pointer is looked at again each tick until then.
    private var coldUntil = 0.0
    /// Apps this reveal woke (E8); put back when the glyph hides, unless a read on them is running.
    private var woken = Set<pid_t>()
    private var hoverTimer: Timer?
    private var hoverTicks = 0
    /// The element under the pointer that the last hover lookup found no paragraph in.
    private var lastMiss: AXUIElement?
    /// Where the pointer last stopped, since when, and whether that place was looked at.
    private var rest: (point: CGPoint, since: Double, looked: Bool)?
    /// Apps hover mode asked to build their tree (AXManualAccessibility: harmless, and it stays set).
    private var asked = Set<pid_t>()
    private var settingsWatch: AnyCancellable?
    private var spaceWatch: NSObjectProtocol?
    static let restDelay = 0.05   // was 0.3; Junior (1 Nov) wants the glyph at once

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func attach(_ model: AppModel) {
        self.model = model
        settingsWatch = model.$settings.map { ($0.readHereHover, $0.readHereHoverApps) }.removeDuplicates(by: ==).sink { [weak self] in self?.setHover($0.0) }
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
        if timer == nil, block != nil, type == .keyDown || (type == .flagsChanged && event != .keyDown && event != .keyUp) { generation += 1; hidePanel(); block = nil }
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
        clickGeneration += 1
        generation += 1
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

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        hidePanel()
        (block, lastPoint) = (nil, nil)
        let reading = model?.highlightedPID
        for pid in wakeLeases.restorableAfterStop(woken, highlighted: reading) { AXWake.restore(pid) }
        woken = wakeLeases.retainedAfterStop(woken)
    }

    private func look() {
        // A key-up the tap missed (it was switched off a moment) must not leave the glyph and this timer running.
        guard revealKeyIsDown() else { apply(state.reset()); stop(); return }
        guard !looking, NSEvent.pressedMouseButtons == 0 else { return }   // an Option-drag or Option-click is no reveal
        let point = Self.pointer()
        looking = true
        let request = generation
        Task { @MainActor in
            defer { looking = false }
            if let block {
                let coveredPoint = Self.coverCheckPoint(block)
                let stale = await PointerCapture.onWorker { Self.moved(block) || coveredPoint.map { Self.covered(block, at: $0) } == true }
                guard request == generation, timer != nil else { return }
                if stale { hidePanel(); (self.block, lastPoint) = (nil, nil) }
            }
            guard point != lastPoint else { return }
            lastPoint = point
            if let block, Self.band(block).contains(point) { return }
            let hit = await PointerCapture.onWorker { PointerCapture.hit(point) }
            guard request == generation, timer != nil else { return }
            guard let hit else {
                hidePanel(); block = nil
                return
            }
            var found = await PointerCapture.onWorker { PointerCapture.block(from: hit.element, pid: hit.pid, point: point) }
            guard request == generation, timer != nil else { return }
            if found == nil, !woken.contains(hit.pid) {
                woken.insert(hit.pid)
                coldUntil = ProcessInfo.processInfo.systemUptime + 1.5
                await AXWake.wake(AXUIElementCreateApplication(hit.pid), pid: hit.pid)
                guard timer != nil else {   // the key went up during the wake, after stop() put back what it knew of
                    if hit.pid != model?.highlightedPID { AXWake.restore(hit.pid) }
                    return
                }
                // A key-up and a fresh hold during the wake: that stop() cleared `woken` before the wake could ledger
                // this app, so this hold's stop() must be the one to put it back.
                woken.insert(hit.pid)
                found = await PointerCapture.onWorker {
                    guard let again = PointerCapture.hit(point), again.pid == hit.pid else { return nil }
                    return PointerCapture.block(from: again.element, pid: again.pid, point: point)
                }
                guard request == generation, timer != nil else { return }
            }
            // A cold tree fills in over the next ticks: look here again while it may still be loading.
            if found == nil, ProcessInfo.processInfo.systemUptime < coldUntil { lastPoint = nil }
            guard timer != nil else { return }   // the key went up meanwhile
            if let found, Self.band(found).contains(Self.pointer()) { show(found) } else if block.map({ !Self.band($0).contains(point) }) ?? true { hidePanel(); block = nil }
        }
    }

    /// Another window or dialog, even the same app's, shows at `point` on the paragraph instead of its own window.
    nonisolated static func covered(_ block: PointerCapture.Block, at point: CGPoint) -> Bool {
        guard let under = PointerCapture.hit(point), under.pid == block.pid else { return true }
        // Only a window positively matched to the paragraph's own counts as uncovered.
        return !PointerCapture.bounded {
            guard let a = PointerCapture.window(of: under.element), let b = PointerCapture.window(of: block.element) else { return false }
            return CFEqual(a, b)
        }
    }

    /// The paragraph is no longer what shows beside the glyph: covered by another window, checked on its first line
    /// clear of the glyph (our own panel answers no hit test). Too short to leave such a point: not checked here.
    private static func coverCheckPoint(_ block: PointerCapture.Block) -> CGPoint? {
        let glyph = Self.glyphFrame(block)
        let x = max(block.frame.minX + min(8, block.frame.width / 2), glyph.maxX + 2)
        return x < block.frame.maxX - 1 ? CGPoint(x: x, y: glyph.midY) : nil
    }

    /// The paragraph's frame moved or changed size (a scroll, a reflow): the glyph no longer belongs where it is.
    nonisolated private static func moved(_ block: PointerCapture.Block) -> Bool {
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
        clickGeneration += 1
        generation += 1
        hidePanel()
        (block, rest, lastPoint) = (nil, nil, nil)
    }

    private func setHover(_ on: Bool) {
        clickGeneration += 1
        generation += 1
        hoverTimer?.invalidate()
        hoverTimer = nil
        rest = nil
        if timer == nil { hidePanel(); block = nil }   // a hover glyph up under the old settings (the app list changed)
        guard on else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.hoverTick() } }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func hoverTick() {
        guard timer == nil, !looking else { return }
        let point = Self.pointer(), now = ProcessInfo.processInfo.systemUptime
        hoverTicks += 1
        if let block, !Self.band(block).contains(point) {
            hidePanel(); self.block = nil; rest = nil
        }
        guard NSEvent.pressedMouseButtons == 0 else { rest = nil; return }
        guard NSEvent.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty else { return }
        if rest.map({ hypot($0.point.x - point.x, $0.point.y - point.y) >= 3 }) ?? true {
            rest = (point, now, false)
        }
        let shouldInspect = rest.map { !$0.looked && now - $0.since >= Self.restDelay } ?? false
        let existing = block
        guard shouldInspect || existing != nil && hoverTicks % 6 == 0 else { return }
        let checkPoint = existing.flatMap(Self.coverCheckPoint)
        let request = generation
        looking = true
        Task { @MainActor in
            defer { looking = false }
            if let existing {
                let stale = await PointerCapture.onWorker { Self.moved(existing) || checkPoint.map { Self.covered(existing, at: $0) } == true }
                guard request == generation, timer == nil else { return }
                if stale { hidePanel(); block = nil; rest = nil }
                else if Self.band(existing).contains(point) { return }
            }
            guard shouldInspect, NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return }
            rest?.looked = true
            let hit = await PointerCapture.onWorker { PointerCapture.hit(point) }
            guard request == generation, timer == nil, let hit else { return }
            if let apps = model?.settings.readHereHoverApps, !apps.isEmpty,
               !apps.contains(NSRunningApplication(processIdentifier: hit.pid)?.bundleIdentifier ?? "") { return }
            if !asked.contains(hit.pid) {
                asked.insert(hit.pid)
                hoverColdUntil = now + 1.5
                _ = await PointerCapture.onWorker {
                    PointerCapture.bounded {
                        AXUIElementSetAttributeValue(AXUIElementCreateApplication(hit.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    }
                }
                guard request == generation, timer == nil else { return }
            }
            if let miss = lastMiss, CFEqual(miss, hit.element), now >= hoverColdUntil { return }
            let found = await PointerCapture.onWorker { PointerCapture.block(from: hit.element, pid: hit.pid, point: point) }
            guard request == generation, timer == nil else { return }
            guard let found, found.start == nil else {
                if now < hoverColdUntil { rest?.looked = false }
                lastMiss = hit.element
                return
            }
            // The pointer may have moved while the other app answered.
            guard Self.band(found).contains(Self.pointer()) else { rest = nil; return }
            lastMiss = nil
            show(found)
        }
    }

    /// Where the pointer may be and keep this glyph: the paragraph and the margin out to the glyph, in AX coordinates.
    static func band(_ block: PointerCapture.Block) -> CGRect {
        let left = glyphFrame(block).minX - 8
        return CGRect(x: left, y: block.frame.minY - 4, width: block.frame.maxX - left, height: block.frame.height + 8)
    }

    /// The glyph's frame in AX (top-left) coordinates: left of the paragraph, centred on its first line, kept on screen.
    static func glyphFrame(_ block: PointerCapture.Block) -> CGRect {
        // Centred on the first line of text where the paragraph's first text run is known (its block may carry padding).
        let top = block.line?.minY ?? block.frame.minY
        let line = min(block.line?.height ?? block.frame.height, 26)
        var x = block.frame.minX - size - gap
        var y = top + (line - size) / 2
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.alphaValue = reduceMotion ? 1 : 0
        p.orderFrontRegardless()
        if !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.05; p.animator().alphaValue = 1 } }
        panel = p
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// A delayed click is valid only while neither the glyph context nor the model's read request changed.
    struct ClickRequest {
        let generation: Int
        let readRevision: UInt64
        func isCurrent(generation: Int, readRevision: UInt64) -> Bool {
            self.generation == generation && self.readRevision == readRevision
        }
    }

    /// Pending AX validation owns its app's wake independently of the reveal key.
    /// This value type keeps stop/release decisions testable without querying Accessibility.
    struct WakeLeases {
        private var pending: [Int: pid_t] = [:]

        mutating func acquire(_ request: Int, pid: pid_t) { pending[request] = pid }
        func contains(_ pid: pid_t) -> Bool { pending.values.contains(pid) }
        func retainedAfterStop(_ woken: Set<pid_t>) -> Set<pid_t> { woken.filter { contains($0) } }
        func restorableAfterStop(_ woken: Set<pid_t>, highlighted: pid_t?) -> Set<pid_t> {
            woken.filter { !contains($0) && $0 != highlighted }
        }
        mutating func release(_ request: Int, highlighted: pid_t?) -> (pid: pid_t, restore: Bool)? {
            guard let pid = pending.removeValue(forKey: request) else { return nil }
            return (pid, !contains(pid) && pid != highlighted)
        }
    }

    func beginClick(readRevision: UInt64, pid: pid_t? = nil) -> ClickRequest {
        generation += 1
        clickGeneration += 1
        if let pid {
            wakeLeases.acquire(clickGeneration, pid: pid)
            AXWake.retainForClick(pid)
            woken.insert(pid)
        }
        return ClickRequest(generation: clickGeneration, readRevision: readRevision)
    }

    private func releaseWake(_ request: ClickRequest) {
        guard let released = wakeLeases.release(request.generation, highlighted: model?.highlightedPID) else { return }
        AXWake.releaseForClick(released.pid, keepAwake: !released.restore)
        if !wakeLeases.contains(released.pid) { woken.remove(released.pid) }
    }

    func accepts(_ request: ClickRequest, readRevision: UInt64) -> Bool {
        request.isCurrent(generation: clickGeneration, readRevision: readRevision)
    }

    private func play() {
        guard let block, let model else { return }
        let request = beginClick(readRevision: model.readRevision, pid: block.pid)
        self.block = nil
        // Leave mouseDown before closing its window. Keep the current read alive during validation,
        // but never let its delayed result replace a newer read or survive a reset or Space change.
        Task { @MainActor [self] in
            defer { releaseWake(request) }
            hidePanel()
            let point = CGPoint(x: block.frame.minX + min(8, block.frame.width / 2), y: Self.glyphFrame(block).midY)
            let covered = await PointerCapture.onWorker { Self.moved(block) || Self.covered(block, at: point) }
            guard accepts(request, readRevision: model.readRevision), !covered else { return }
            let reservation = model.reserve("user")
            await model.captureHereAndRead(id: reservation, point: point, block: block)
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
