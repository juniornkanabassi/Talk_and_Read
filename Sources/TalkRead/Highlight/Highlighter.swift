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
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            // Re-query at once rather than at the next tick: the box should feel glued to the text (Junior, 12 Sep).
            MainActor.assumeIsolated { self?.scrolled() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate(); self?.overlay.follow() } }   // its windows rise over the box
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { _ = self?.overlay.follow() } }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pausedTimer?.invalidate()
        pausedTimer = nil
        stateObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
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
            timer?.invalidate()
            timer = nil
            guard pausedTimer == nil else { return }
            // ponytail: a 5 Hz window-server poll (~0.1 % of a core) while paused; AXObserver move/minimise notifications
            // on the source window would make it zero if long pauses matter.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pausedTick() } }
            RunLoop.main.add(timer, forMode: .common)
            pausedTimer = timer
        case .preparing:
            break
        case .finished, .failed:
            stop()
        }
    }

    /// A wheel scroll over the window being read re-queries at once, at most once per display frame (16 ms; trackpad
    /// momentum sends up to about 120 events a second); scrolls over other windows change nothing (efficiency fix 4).
    private func scrolled() {
        guard overlay.panel?.frame.contains(NSEvent.mouseLocation) == true else { return }
        invalidate()
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

    private func invalidate() {
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
        guard overlay.follow(), overlay.panel?.frame.size != size else { return }
        invalidate()
        tick()
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
