// Word boxes for apps that expose no text geometry: one ScreenCaptureKit image of the capture's window, Vision text
// recognition, words aligned to the selection with NodeAlignment. Only with Screen Recording granted. The selection is
// found by its highlight colour (PLAN decision 17), never by the pointer; ambiguous copies with no highlight hide.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import TalkReadCore
import Vision

@MainActor final class OCRLocator {
    struct Word { let text: String; let box: CGRect /* normalised, lower-left origin */; let highlighted: Bool }

    private let pid: pid_t
    private let axWindow: AXUIElement?
    private let selectionWords: [String]
    private var windowID: CGWindowID?
    private var windowSize: CGSize?
    private var words: [Word] = []
    private var map: [Int: Int] = [:]          // token index -> word index
    private var lastCapture: TimeInterval = 0
    private var inFlight = false
    private var stale = true
    /// Bumped whenever the boxes stop matching the window (scroll, resize): a recognition started under an older
    /// generation, for another window or at another size is discarded when it finishes (Sol #11).
    private var generation = 0
    private var discarded = 0
    private var missingSince: TimeInterval?
    /// Seconds a spoken word may stay missing before the next capture: 1, 2, 4, then 8 (a read running below the visible
    /// text otherwise re-runs Vision every second, about 0.9 s of CPU each); back to 1 on a scroll, resize or new window.
    private var missingWait = 1.0
    private var lastAsked = 0
    /// What the last recognition found, for logs and the self-test.
    private(set) var summary = "no capture yet"
    /// True until the first recognition has finished (a nil rect then means "not yet", not "not there").
    private(set) var isPending = true

    init(capture: Capture, tokens: [Token]) {
        pid = capture.pid
        axWindow = capture.window
        selectionWords = tokens.map { $0.text.lowercased() }
    }

    private static var requestedAccess = false
    /// Screen Recording preflight; asks the system at most once per launch (never in a loop).
    static func hasAccess(requestOnce: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if requestOnce, !requestedAccess {
            requestedAccess = true
            _ = CGRequestScreenCaptureAccess()
        }
        return false
    }

    /// Cocoa screen rect for token `index`, or nil. Boxes are kept relative to the window and placed on its current
    /// frame, so a window move needs no new capture; a resize, a scroll (debounced 150 ms) or a word missing for 1 s does
    /// (then 2, 4 and 8 s while it stays missing).
    func rect(forTokenIndex index: Int) -> CGRect? {
        lastAsked = index
        guard let frame = currentWindowFrame() else {
            isPending = false   // no window to capture: nothing to wait for, so the AX paths keep their retries
            return nil
        }
        if let size = windowSize, size != frame.size { (generation, map, windowSize, stale, missingWait) = (generation + 1, [:], nil, true, 1) }   // re-laid out
        refreshIfNeeded()
        guard let w = map[index] else {
            let now = Date().timeIntervalSince1970
            if let since = missingSince {
                if now - since > missingWait { stale = true; missingSince = now; missingWait = min(missingWait * 2, 8) }
            } else {
                missingSince = now
            }
            return nil
        }
        missingSince = nil
        let b = words[w].box
        return CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + b.minY * frame.height,
                      width: b.width * frame.width, height: b.height * frame.height)
    }

    /// A scroll moved the text: hide now, capture again once scrolling has paused for 150 ms.
    func invalidate() {
        generation += 1
        missingWait = 1
        let current = generation
        map = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == current else { return }
            self.stale = true
            self.refreshIfNeeded()
        }
    }

    /// At most two captures a second, one at a time.
    private func refreshIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard stale, !inFlight, now - lastCapture >= 0.5, let size = currentWindowFrame()?.size, let id = windowID else { return }
        inFlight = true
        lastCapture = now
        stale = false
        let from = isPending ? 0 : lastAsked
        let requested = generation
        Task { @MainActor in
            defer { inFlight = false }
            let image: CGImage, found: [Word]
            do {
                image = try await Self.captureWindow(id)
                found = try await Self.recognizeWords(image)
            } catch {
                summary = "capture or recognition failed: \(error.localizedDescription)"
                isPending = false
                return
            }
            // A scroll, resize or another window while this ran: its boxes describe a layout no longer on screen.
            guard generation == requested, currentWindowFrame()?.size == size, windowID == id else {
                discarded += 1
                if generation == requested { stale = true }   // after a scroll, its own 150 ms debounce asks again
                summary = "discarded \(discarded) stale recognition(s), recapturing"
                return
            }
            isPending = false
            words = found
            windowSize = size
            let highlighted = Set(found.indices.filter { found[$0].highlighted })
            // From the selection's start, anchored on the highlight; mid-read (after a scroll took the opening words away)
            // from the word being asked for, which hides rather than picks between equal copies.
            let stream = found.map { $0.text.lowercased() }
            map = NodeAlignment.best(stream, selectionWords, from: 0, prefer: highlighted.isEmpty ? nil : highlighted)
            if from > 0, map[from] == nil { map = NodeAlignment.best(stream, selectionWords, from: from) }
            summary = "\(image.width)x\(image.height) px, \(found.count) words, \(highlighted.count) in the selection colour, placed \(map.count); discarded \(discarded) stale"
        }
    }

    // MARK: - Window

    /// The pid's on-screen window whose bounds match the AX window frame (both top-left global coordinates).
    private func findWindowID() -> CGWindowID? { WindowPin.windowID(pid: pid, axFrame: axWindow.flatMap(axFrame)) }

    /// The window's current frame in Cocoa coordinates (one CGWindowList lookup, no AX round trip).
    private func currentWindowFrame() -> CGRect? {
        guard let id = windowID ?? findWindowID() else { return nil }
        if id != windowID { missingWait = 1 }   // a new window
        windowID = id
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String], let rect = CGRect(dictionaryRepresentation: dict as! CFDictionary)
        else { windowID = nil; return nil }
        return Locator.convert(topLeftScreenRect: rect)
    }

    // MARK: - Capture and recognition (shared with ScreenshotCapture)

    /// Only that window, at its backing scale, no shadow, so the image maps 1:1 onto the window's frame.
    nonisolated static func captureWindow(_ id: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    nonisolated static func textRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-GB"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        return request
    }

    /// Every recognised word with its own box (`boundingBox(for:)` on the candidate string) and whether the pixels just
    /// outside the box are the system selection colour.
    nonisolated static func recognizeWords(_ image: CGImage) async throws -> [Word] {
        let observations = try await textRequest().perform(on: image)
        let pixels = Pixels(image)
        let selection = selectionColours()
        var words: [Word] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            for token in TextKit.tokenize(string) {
                let utf16 = string.utf16
                let lower = String.Index(utf16.index(utf16.startIndex, offsetBy: token.range.lowerBound), within: string)
                let upper = String.Index(utf16.index(utf16.startIndex, offsetBy: token.range.upperBound), within: string)
                guard let lower, let upper, let box = candidate.boundingBox(for: lower..<upper)?.boundingBox.cgRect else { continue }
                words.append(Word(text: token.text, box: box, highlighted: pixels?.isHighlighted(box, colours: selection) ?? false))
            }
        }
        return words
    }

    /// `selectedTextBackgroundColor` and its unemphasised (inactive window) variant in the system appearance, as sRGB.
    nonisolated static func selectionColours() -> [(CGFloat, CGFloat, CGFloat)] {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        var result: [(CGFloat, CGFloat, CGFloat)] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            for colour in [NSColor.selectedTextBackgroundColor, NSColor.unemphasizedSelectedTextBackgroundColor] {
                if let c = colour.usingColorSpace(.sRGB) { result.append((c.redComponent, c.greenComponent, c.blueComponent)) }
            }
        }
        return result
    }

    /// The image redrawn into a known RGBA8 sRGB buffer so pixels can be read.
    struct Pixels {
        let width: Int, height: Int
        private let data: [UInt8]

        init?(_ image: CGImage) {
            let (width, height) = (image.width, image.height)
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            (self.width, self.height, data) = (width, height, buffer)
        }

        /// RGB at (x, y) with y counted from the top row; nil outside the image.
        func colour(x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return (CGFloat(data[i]) / 255, CGFloat(data[i + 1]) / 255, CGFloat(data[i + 2]) / 255)
        }

        /// Whether the word sits on the selection colour: a selection paints the whole line band, so most of the box
        /// between the glyph strokes is that colour. A grid of points inside the box is sampled (robust to a box a few
        /// pixels off, which Vision's per-range boxes can be); highlighted when at least a third match.
        func isHighlighted(_ box: CGRect, colours: [(CGFloat, CGFloat, CGFloat)]) -> Bool {
            var hits = 0, total = 0
            for i in 1...6 {
                for j in 1...3 {
                    let x = (box.minX + box.width * CGFloat(i) / 7) * CGFloat(width)
                    let y = (1 - box.minY - box.height * CGFloat(j) / 4) * CGFloat(height)
                    guard let c = colour(x: Int(x), y: Int(y)) else { continue }
                    total += 1
                    if colours.contains(where: { max(abs($0.0 - c.0), abs($0.1 - c.1), abs($0.2 - c.2)) <= 0.06 }) { hits += 1 }
                }
            }
            return total > 0 && hits * 3 >= total
        }
    }
}
