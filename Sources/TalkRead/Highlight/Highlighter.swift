// 30 Hz tick while reading: the session's current word -> rect from the locator chain -> Overlay (ReadAlong's tick,
// timed by our own media clock through ReadSession.currentToken). Geometry is queried live for each new word, after a
// scroll, activation or window change, and at 10 Hz in between; the sentence tint is cached only while its anchor word
// still reports the rect it had when the cache was filled.
// Every third tick first pins the overlay to the source window (H2); while that window is off screen nothing is located.
// Paused, a 5 Hz follow keeps the box on a moving window and hides it with the window, with no AX work.
import AppKit
import Combine
import TalkReadCore

@MainActor final class Highlighter {
    private let session: ReadSession
    private let overlay: Overlay
    /// `Settings.useOCRFallback`; set before `start()`.
    var useOCRFallback = true
    private var locator: Locator?
    private var timer: Timer?
    private var pausedTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var resolvedAt: TimeInterval = 0
    private var ticks = 0
    private var stateObserver: AnyCancellable?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    /// Where a plain single click went down, until it is released or dragged.
    private var clickDown: CGPoint?
    private var clickGeneration = 0
    private var activationObserver: NSObjectProtocol?
    private var sentenceCache: (sentence: Int, rects: [CGRect], anchor: Range<Int>, anchorRect: CGRect?)?
    private lazy var sentenceTokens: [Int: Range<Int>] = {
        var ranges: [Int: Range<Int>] = [:]
        for (i, token) in session.tokens.enumerated() { ranges[token.sentence] = (ranges[token.sentence]?.lowerBound ?? i)..<(i + 1) }
        return ranges
    }()
    private var lastLogged: Int?
    /// The word last asked of AX, when, and whether something (scroll, activation, window change) makes the next tick ask.
    private var shownIndex: Int?
    private var queriedAt: TimeInterval = 0
    private var requery = true
    private var scrollTickedAt: TimeInterval = 0
    private var scrollTickQueued = false
    /// Whether the scroll gesture in progress (momentum included) moves the source window; decided at its start.
    private var scrollingSource = false
    /// A paused read keeps asking until then after a scroll over it (the app and OCR settle a moment after the event).
    private var settleUntil: TimeInterval = 0
    private let debug = ProcessInfo.processInfo.environment["TALKREAD_DEBUG"] == "1"

    init(session: ReadSession, style: Overlay.Style) {
        self.session = session
        self.overlay = Overlay(style: style)
    }

    /// Only for captures with a place on screen (`Capture.hasGeometry`); provided text and most clipboard text have none.
    func start() {
        guard locator == nil, let capture = session.capture, capture.hasGeometry else { return }
        locator = Locator(capture: capture, useOCR: useOCRFallback)
        resolveSource()
        stateObserver = session.$state.sink { [weak self] state in self?.stateChanged(state) }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Re-query at once rather than at the next tick: the box should feel glued to the text (Junior, 12 Sep).
            let (phase, momentum) = (event.phase, event.momentumPhase)
            MainActor.assumeIsolated { self?.scrolled(phase: phase, momentum: momentum) }
        }
        // A plain click on a word of the text being read jumps the read there, forwards or back (Speechify's way; Junior,
        // 1 Nov). The app still gets its click. Only while playing: a paused read leaves clicks alone (copying, selecting).
        // The seek happens on the mouse-up of a single plain click that did not drag (a drag is a selection).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let location = NSEvent.mouseLocation, type = event.type, count = event.clickCount
            let plain = event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .leftMouseDown:
                    self.clickGeneration += 1
                    self.clickDown = plain && count == 1 ? location : nil
                case .leftMouseDragged:
                    self.clickGeneration += 1
                    self.clickDown = nil
                case .leftMouseUp:
                    if let down = self.clickDown, count == 1, hypot(down.x - location.x, down.y - location.y) < 3 { self.clicked(at: down) }
                    self.clickDown = nil
                default: break
                }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate(); self?.overlay.follow() } }   // its windows rise over the box
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate(); _ = self?.overlay.follow() } }
    }

    func stop() {
        clickGeneration += 1
        if let locator { Log.write("highlight ended: path=\(locator.pathUsed.rawValue), node map \(locator.nodeMapSummary), OCR \(locator.ocrSummary)") }
        timer?.invalidate()
        timer = nil
        pausedTimer?.invalidate()
        pausedTimer = nil
        stateObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        overlay.hide()
        if let pid = session.capture?.pid { AXWake.restore(pid) }   // the read ended: the app is no longer "woken" (E8)
        locator = nil
        sentenceCache = nil
    }

    private func stateChanged(_ state: ReadSession.State) {
        switch state {
        case .playing:
            pausedTimer?.invalidate()
            pausedTimer = nil
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .paused:   // the box stays on its word (a scroll still moves it with the text) and with its window
            clickGeneration += 1
            timer?.invalidate()
            timer = nil
            guard pausedTimer == nil else { return }
            // ponytail: a 5 Hz window-server poll (~0.1 % of a core) while paused; AXObserver move/minimise notifications
            // on the source window would make it zero if long pauses matter.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pausedTick() } }
            RunLoop.main.add(timer, forMode: .common)
            pausedTimer = timer
        case .preparing:
            clickGeneration += 1
            break
        case .finished, .failed:
            stop()
        }
    }

    /// A scroll of the window being read re-queries at once, at most once per display frame (16 ms; trackpad momentum
    /// sends up to about 120 events a second); scrolls of other windows change nothing (efficiency fix 4). The window
    /// receiving the scroll is the one under the pointer when the gesture starts; its momentum keeps that answer (Sol
    /// 0.5.0 #3).
    private func scrolled(phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        scrollingSource = Self.scrollTargetsSource(phase: phase, momentum: momentum, previous: scrollingSource, hit: pointerOverSource)
        guard scrollingSource else { return }
        invalidate()
        settleUntil = ProcessInfo.processInfo.systemUptime + 2
        let wait = scrollTickedAt + 0.016 - ProcessInfo.processInfo.systemUptime
        if wait <= 0 {
            scrollTickedAt = ProcessInfo.processInfo.systemUptime
            return tick()
        }
        guard !scrollTickQueued else { return }
        scrollTickQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollTickQueued = false
                self.scrollTickedAt = ProcessInfo.processInfo.systemUptime
                self.tick()
            }
        }
    }

    /// A clean click on a word of the text being read (Cocoa screen point): the read jumps there, unless it is the
    /// word being spoken (a restart would only stutter).
    private func clicked(at point: CGPoint) {
        clickGeneration += 1
        guard session.state == .playing, let locator, pointerOverSource() else { return }
        let request = ClickRequest(click: clickGeneration, read: session.generation,
                                   locator: ObjectIdentifier(locator), session: ObjectIdentifier(session))
        Task { @MainActor [weak self, weak locator] in
            guard let locator, let range = await locator.wordRange(at: point), let self,
                  let currentLocator = self.locator,
                  request.isCurrent(click: self.clickGeneration, read: self.session.generation,
                                    locator: ObjectIdentifier(currentLocator), session: ObjectIdentifier(self.session),
                                    playing: self.session.state == .playing),
                  self.pointerOverSource(),
                  let token = self.session.tokens.firstIndex(where: { $0.range == range }), token != self.session.currentToken else { return }
            self.session.seek(token: token)
        }
    }

    struct ClickRequest {
        let click: Int
        let read: Int
        let locator: ObjectIdentifier
        let session: ObjectIdentifier

        func isCurrent(click: Int, read: Int, locator: ObjectIdentifier, session: ObjectIdentifier, playing: Bool) -> Bool {
            playing && self.click == click && self.read == read && self.locator == locator && self.session == session
        }
    }

    /// The window under the pointer, looking through our own click-through panel, is the source window.
    private func pointerOverSource() -> Bool {
        guard let source = overlay.source else { return false }
        let point = NSEvent.mouseLocation
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let panel = overlay.panel, number == panel.windowNumber {
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: panel.windowNumber)
        }
        return number > 0 && CGWindowID(number) == source
    }

    /// Whether a scroll event moves the source window (pure; checked by the TTS self-test): a plain wheel event and the
    /// start of a gesture are hit-tested, its later phases and its momentum keep that answer.
    nonisolated static func scrollTargetsSource(phase: NSEvent.Phase, momentum: NSEvent.Phase, previous: Bool, hit: () -> Bool) -> Bool {
        !momentum.isEmpty || !phase.isDisjoint(with: [.changed, .stationary, .ended, .cancelled]) ? previous : hit()
    }

    private func invalidate() {
        clickGeneration += 1
        locator?.invalidate()
        sentenceCache = nil
        requery = true
    }

    /// The capture's window, matched by its AX frame among the app's on-screen windows (else the app's frontmost);
    /// retried once a second while unknown. Until then nothing is drawn.
    private func resolveSource() {
        guard overlay.source == nil, let capture = session.capture else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - resolvedAt >= 1 else { return }
        resolvedAt = now
        overlay.source = WindowPin.windowID(pid: capture.pid, axFrame: capture.window.flatMap(axFrame))
    }

    /// Paused: follow the window only; a resize may have reflowed the text, so locate again then.
    private func pausedTick() {
        let size = overlay.panel?.frame.size
        guard overlay.follow() else { return }
        if overlay.panel?.frame.size != size { invalidate(); return tick() }
        // After a scroll over the paused read, keep asking for 2 s: the app may still be moving the text when the event
        // arrives, and OCR recognises the window again a moment later (Sol 0.5.0 #3).
        if ProcessInfo.processInfo.systemUptime < settleUntil { requery = true; tick() }
    }

    private func tick() {
        guard let locator, session.state == .playing || session.state == .paused else { return }
        resolveSource()
        // The pin is a window-server query (~0.2 ms): every third tick (10 Hz) follows a move or a raise closely enough,
        // and app activations and Space changes call follow() at once. Off screen (another Space, minimised, hidden,
        // closed or not yet known): nothing to locate.
        ticks += 1
        if ticks % 3 == 1 {
            let frame = overlay.panel?.frame
            guard overlay.follow() else { return }
            if overlay.panel?.frame != frame { locator.windowChanged(); requery = true }   // moved or resized
        } else if overlay.panel == nil {
            return
        }
        guard let index = session.currentToken, session.tokens.indices.contains(index) else {
            overlay.show(word: nil, sentence: [])
            return
        }
        // Each query is AX round trips into the app being read (word bounds, the tint anchor's): at once for a new word,
        // a scroll, an activation or a window change, otherwise at 10 Hz for scrolls that post no wheel event.
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.needsQuery(index: index, shown: shownIndex, forced: requery, sinceLast: now - queriedAt) else { return }
        (shownIndex, requery, queriedAt) = (index, false, now)
        let token = session.tokens[index]
        // Every AX request below waits 0.25 s at most, not the system's default of several seconds: an app that stops
        // answering (or a Mac deep in swap) must not hold the main thread (work Mac, 7 Nov 2026).
        PointerCapture.bounded(0.25) { locate(index: index, token: token, locator: locator) }
    }

    private func locate(index: Int, token: Token, locator: Locator) {
        let wordRect = locator.rect(forWord: token.range)
        if debug, lastLogged != index {
            lastLogged = index
            Log.write("highlight word=\(index) path=\(locator.pathUsed.rawValue) rect=\(wordRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")")
        }
        var sentenceRects: [CGRect] = []
        if overlay.style.tintEnabled {
            // Scroll bar drags, key scrolls and page scripts post no scrollWheel event, so the cache is trusted only while
            // its anchor word still sits where it was.
            if let cache = sentenceCache, cache.sentence == token.sentence,
               (cache.anchor == token.range ? wordRect : locator.tintRect(forWord: cache.anchor)) == cache.anchorRect {
                sentenceRects = cache.rects
            } else {
                sentenceRects = (sentenceTokens[token.sentence] ?? index..<index + 1).compactMap { locator.tintRect(forWord: session.tokens[$0].range) }
                // An empty result is kept only while the word itself is out of view; with it visible, retry next tick.
                if !sentenceRects.isEmpty || wordRect == nil { sentenceCache = (token.sentence, sentenceRects, token.range, wordRect) }
            }
        }
        overlay.show(word: wordRect, sentence: sentenceRects)
    }

    /// Whether a tick asks AX again (efficiency fix 3); 0.09 s is every third 30 Hz tick. Checked by the TTS self-test.
    nonisolated static func needsQuery(index: Int, shown: Int?, forced: Bool, sinceLast: Double) -> Bool {
        index != shown || forced || sinceLast >= 0.09
    }
}
