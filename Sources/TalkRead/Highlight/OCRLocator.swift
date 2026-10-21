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
    private var scrollGeneration = 0
    private var missingSince: TimeInterval?
    private var lastAsked = 0
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
    /// frame, so a window move needs no new capture; a resize, a scroll (debounced 150 ms) or a word missing for 1 s does.
    func rect(forTokenIndex index: Int) -> CGRect? {
        lastAsked = index
        guard let frame = currentWindowFrame() else { return nil }
        if let size = windowSize, size != frame.size { (map, windowSize, stale) = ([:], nil, true) }   // re-laid out
        refreshIfNeeded()
        guard let w = map[index] else {
            let now = Date().timeIntervalSince1970
            if let since = missingSince {
                if now - since > 1 { stale = true; missingSince = now }
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
        scrollGeneration += 1
        let generation = scrollGeneration
        map = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.scrollGeneration == generation else { return }
            self.stale = true
            self.refreshIfNeeded()
        }
    }

    /// At most two captures a second, one at a time.
    private func refreshIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard stale, !inFlight, now - lastCapture >= 0.5, let id = windowID ?? findWindowID() else { return }
        windowID = id
        inFlight = true
        lastCapture = now
        stale = false
        let from = isPending ? 0 : lastAsked
        Task { @MainActor in
            defer { inFlight = false; isPending = false }
            guard let image = try? await Self.captureWindow(id), let found = try? await Self.recognizeWords(image) else { return }
            words = found
            windowSize = currentWindowFrame()?.size
            let highlighted = Set(found.indices.filter { found[$0].highlighted })
            map = NodeAlignment.best(found.map { $0.text.lowercased() }, selectionWords, from: from,
                                     prefer: highlighted.isEmpty ? nil : highlighted)
        }
    }

    // MARK: - Window

    /// The pid's on-screen window whose bounds match the AX window frame (both top-left global coordinates).
    private func findWindowID() -> CGWindowID? {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let candidates = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let target = axWindow.flatMap(axFrame)
        func bounds(_ entry: [String: Any]) -> CGRect {
            entry[kCGWindowBounds as String].flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero
        }
        let best = target.map { t in candidates.min { a, b in Self.distance(bounds(a), t) < Self.distance(bounds(b), t) } } ?? candidates.first
        return (best?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The window's current frame in Cocoa coordinates (one CGWindowList lookup, no AX round trip).
    private func currentWindowFrame() -> CGRect? {
        guard let id = windowID ?? findWindowID() else { return nil }
        windowID = id
        guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
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

        /// At least two of the four points just outside the box (left, right, above, below) match a selection colour.
        func isHighlighted(_ box: CGRect, colours: [(CGFloat, CGFloat, CGFloat)]) -> Bool {
            let minX = box.minX * CGFloat(width), maxX = box.maxX * CGFloat(width)
            let top = (1 - box.maxY) * CGFloat(height), bottom = (1 - box.minY) * CGFloat(height)
            let margin = max(2, CGFloat(height) / 600)   // a couple of pixels at any scale
            let points = [(minX - margin * 1.5, (top + bottom) / 2), (maxX + margin * 1.5, (top + bottom) / 2),
                          ((minX + maxX) / 2, top - margin), ((minX + maxX) / 2, bottom + margin)]
            let hits = points.filter { p in
                guard let c = colour(x: Int(p.0), y: Int(p.1)) else { return false }
                return colours.contains { max(abs($0.0 - c.0), abs($0.1 - c.1), abs($0.2 - c.2)) <= 0.06 }
            }
            return hits.count >= 2
        }
    }
}
