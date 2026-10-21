// 30 Hz tick while reading: the session's current word -> rect from the locator chain -> Overlay (ReadAlong's tick,
// timed by our own media clock through ReadSession.currentToken). Geometry is queried live every tick; only the
// sentence tint is cached, and only while its anchor word still reports the rect it had when the cache was filled.
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
    private let debug = ProcessInfo.processInfo.environment["TALKREAD_DEBUG"] == "1"

    init(session: ReadSession, style: Overlay.Style) {
        self.session = session
        self.overlay = Overlay(style: style)
    }

    /// Only for captures with a place on screen (.accessibility, .copied, .cursor, .ocr); clipboard and provided text
    /// have none, so no overlay.
    func start() {
        guard locator == nil, let capture = session.capture, capture.hasGeometry else { return }
        locator = Locator(capture: capture, useOCR: useOCRFallback)
        stateObserver = session.$state.sink { [weak self] state in self?.stateChanged(state) }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            // Re-query at once rather than at the next tick: the box should feel glued to the text (Junior, 12 Sep).
            MainActor.assumeIsolated { self?.invalidate(); self?.tick() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stateObserver = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        overlay.hide()
        locator = nil
        sentenceCache = nil
    }

    private func stateChanged(_ state: ReadSession.State) {
        switch state {
        case .playing:
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .paused:   // the box stays where it is (a scroll still moves it with the text)
            timer?.invalidate()
            timer = nil
        case .preparing:
            break
        case .finished, .failed:
            stop()
        }
    }

    private func invalidate() {
        locator?.invalidate()
        sentenceCache = nil
    }

    private func tick() {
        guard let locator, session.state == .playing || session.state == .paused else { return }
        guard let index = session.currentToken, session.tokens.indices.contains(index) else {
            overlay.show(word: nil, sentence: [])
            return
        }
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
        if overlay.reorderedOffSpace {
            overlay.reorderedOffSpace = false
            if debug { Log.write("highlight overlay was off the active Space, brought back") }
        }
    }
}
