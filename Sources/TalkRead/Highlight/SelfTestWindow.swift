// `TalkRead --selftest-window` (R4, R5, R6, R7, R7c, R7d, R12, E8, H1, H2, H3). Headless first: PasteboardGate, the
// coordinate flip, screenshot OCR and the OCR selection-colour anchor on rendered bitmaps, the overlay pin on recorded
// window-server snapshots and on live windows placed off every display. Then, on the Prompter XL screen only, one test
// window (NSTextView, WKWebView, PDFView, rendered-text NSImageView, a terminal-style text view) shown without activating
// the app or becoming key.
// Each pane is read by a child process of this binary through the real TextCapture and Locator: AX calls into one's own
// process are answered in-process, where WebKit's remote web content has no role on the main thread and crashes off it,
// so only a second process sees what any other app sees. Finally a read-only node-map probe on a Chromium/Electron window.
import AppKit
import PDFKit
import TalkReadCore
import WebKit

enum SelfTestWindow {
    static func run() -> Int32 {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if let i = args.firstIndex(of: "--client"), i + 3 < args.count, let host = pid_t(args[i + 1]) {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await SelfTestClient.run(host: host, pane: args[i + 2], pasteboard: args[i + 3])) }
        } else {
            app.setActivationPolicy(.prohibited)   // never activated: Junior's app keeps focus (COMMON)
            Task { @MainActor in exit(await SelfTestHost().run()) }
        }
        app.run()
        return 1
    }

    static let phrase = "The highlight follows every spoken word without guessing."
    static let textParagraph = "Talk & Read draws a yellow box on each word as the voice reads it aloud. \(phrase) Some sentences repeat on purpose, so the locator has to choose the right copy. \(phrase) When it cannot be sure, it hides the box instead."
    static let webParagraph = "Talk & Read draws a yellow box on each word as the voice reads it aloud. \(phrase) When it cannot be sure, it hides the box instead."
    static let ocrSentence = "Reading aloud keeps the eye and the ear together on every line."
    static let ocrText = "\(ocrSentence) A different sentence sits between the two copies. \(ocrSentence)"
    static let turned = "Sideways pages keep their boxes."

    /// Text drawn black on white into a 1x sRGB bitmap, optionally with the selection colour behind `highlight` (line
    /// fragments, like a real selection). `rect` gives a character range's glyph rect in image points, top-left origin.
    @MainActor static func render(_ text: String, width: CGFloat, fontSize: CGFloat, highlight: NSRange? = nil)
        -> (image: CGImage, rect: (NSRange) -> CGRect) {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width - 40, height: 10_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height) + 40)
        let origin = CGPoint(x: 20, y: 20)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        if let highlight, let c = OCRLocator.selectionColours().first {
            NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
            let glyphs = layout.glyphRange(forCharacterRange: highlight, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { r, _ in
                r.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
        NSGraphicsContext.restoreGraphicsState()
        let rect = { (range: NSRange) -> CGRect in
            _ = storage   // the layout manager does not retain its text storage
            return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
        }
        return (context.makeImage()!, rect)
    }

    static func ns(_ r: Range<Int>, plus offset: Int = 0) -> NSRange { NSRange(location: r.lowerBound + offset, length: r.count) }
}

// MARK: - Host

@MainActor final class SelfTestHost: NSObject, WKNavigationDelegate {
    private var results: [(name: String, status: String, detail: String)] = []
    private let pasteboardName = "com.juniornkanabassi.TalkAndRead.selftest.\(getpid())"
    private var loaded: CheckedContinuation<Void, Never>?

    private func record(_ name: String, _ ok: Bool?, _ detail: String) {
        results.append((name, ok.map { $0 ? "PASS" : "FAIL" } ?? "SKIP", detail))
        FileHandle.standardError.write(Data("[\(results.last!.status)] \(name): \(detail)\n".utf8))
    }

    func run() async -> Int32 {
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        await pasteboardChecks()
        let probe = CGRect(x: 100, y: 50, width: 200, height: 20)
        record("Coordinate flip", Locator.convert(topLeftScreenRect: Locator.convert(topLeftScreenRect: probe)) == probe, "AX/CG top-left <-> Cocoa is its own inverse")
        pageBaseCheck()
        pinPlacementCheck()
        await wakeCheck("E8 wake, app with no text", bare: true)   // before any window exists in this host
        await pinnedOverlayCheck()
        await screenshotTextCheck()
        await ocrHighlightCheck()
        if let screen = NSScreen.screens.first(where: { $0.localizedName.contains("Prompter") }) {
            await windowChecks(on: screen)
        } else {
            record("Test window panes", nil, "not run: no screen named Prompter (Elgato Prompter XL) connected")
        }
        await chromiumProbe()
        let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        record("No focus change", frontAfter == frontBefore && !NSApp.isActive, "frontmost pid \(frontBefore.map(String.init) ?? "-") -> \(frontAfter.map(String.init) ?? "-"), our app active: \(NSApp.isActive)")
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).releaseGlobally()

        print("\nTalk & Read --selftest-window")
        for r in results { print("\(r.status.padding(toLength: 5, withPad: " ", startingAt: 0)) \(r.name.padding(toLength: 38, withPad: " ", startingAt: 0)) \(r.detail)") }
        let failed = results.filter { $0.status == "FAIL" }.count
        print("\(results.filter { $0.status == "PASS" }.count) passed, \(failed) failed, \(results.filter { $0.status == "SKIP" }.count) skipped")
        fflush(stdout)
        return failed == 0 ? 0 : 1
    }

    // MARK: PasteboardGate (R7), on a private pasteboard

    private func pasteboardChecks() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(pasteboardName + ".gate"))
        defer { pb.releaseGlobally() }
        let gate = PasteboardGate(pasteboard: pb)
        let binaryType = NSPasteboard.PasteboardType("com.juniornkanabassi.talkread.selftest.binary")
        func contents() -> [[String: Data]] {
            (pb.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } })
            }
        }
        func fill() -> [[String: Data]] {
            pb.clearContents()
            let first = NSPasteboardItem()
            first.setString("Original first item", forType: .string)
            first.setData(Data([0, 1, 2, 255, 254, 0, 42]), forType: binaryType)
            first.setData(Data("{\\rtf1\\ansi Original}".utf8), forType: .rtf)
            let second = NSPasteboardItem()
            second.setString("Second item", forType: .string)
            second.setData(Data((0..<4096).map { UInt8($0 % 251) }), forType: .png)
            pb.writeObjects([first, second])
            return contents()
        }

        var original = fill()
        let markers = await gate.transaction { () -> Bool in
            gate.write("temporary text")
            let types = Set(pb.types?.map(\.rawValue) ?? [])
            return pb.string(forType: .string) == "temporary text"
                && types.isSuperset(of: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"])
        }
        let restored = contents()
        record("Pasteboard multi-type restore", markers && restored == original,
               "\(original.count) items, \(original.map(\.count).reduce(0, +)) types restored byte for byte; temporary item marked transient/concealed/auto-generated: \(markers)")

        original = fill()
        var firstEnded = Date.distantFuture, secondStarted = Date.distantPast
        var secondSaw: String?
        let insertion = Task { @MainActor in
            await gate.transaction {
                gate.write("dictated text")
                try? await Task.sleep(for: .milliseconds(300))   // an insertion's restore wait
                firstEnded = Date()
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let capture = Task { @MainActor in
            await gate.transaction {
                secondStarted = Date()
                secondSaw = pb.pasteboardItems?.first?.string(forType: .string)
                gate.write("copied selection")
            }
        }
        await insertion.value
        await capture.value
        record("Pasteboard overlapping transactions", contents() == original && secondStarted >= firstEnded && secondSaw == "Original first item",
               "second started \(Int(secondStarted.timeIntervalSince(firstEnded) * 1000)) ms after the first restored, saw \"\(secondSaw ?? "nil")\"; original kept")

        _ = fill()
        await gate.transaction {
            gate.write("temporary text")
            try? await Task.sleep(for: .milliseconds(50))
            pb.clearContents()   // the user copies something meanwhile
            pb.setString("The user's new copy", forType: .string)
        }
        record("Pasteboard external change kept", pb.string(forType: .string) == "The user's new copy" && pb.pasteboardItems?.count == 1,
               "a change by someone else during the transaction is left alone")

        func copy(_ text: String) {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        original = fill()
        let copied = await gate.transaction { () -> TextCapture.Copied in
            let before = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { copy("copied by the app") }   // the app answering Edit ▸ Copy
            return await TextCapture.readCopy(gate: gate, before: before)
        }
        let start = Date()
        let changed = await gate.transaction { await gate.waitForChange(from: pb.changeCount, timeout: 0.3) }
        let waited = Date().timeIntervalSince(start)
        record("Pasteboard copy wait", copied == .text("copied by the app") && contents() == original && !changed && (0.28...0.6).contains(waited),
               "read \(copied) then restored; no change times out after \(Int(waited * 1000)) ms")

        // Sol #3: Junior copies just after the app answered (inside the 20 ms settle, or between the wait and the read).
        // Not ours: nothing is read and his newer copy is never restored over.
        _ = fill()
        let duringSettle = await gate.transaction { () -> TextCapture.Copied in
            let before = pb.changeCount
            copy("copied by the app")   // the app answers at once; the first observed change is this one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { copy("Junior's newer copy") }
            return await TextCapture.readCopy(gate: gate, before: before)
        }
        let keptAfterSettle = pb.string(forType: .string) == "Junior's newer copy" && pb.pasteboardItems?.count == 1
        _ = fill()
        let beforeRead = await gate.transaction { () -> String? in
            let before = pb.changeCount
            copy("copied by the app")
            guard await gate.waitForChange(from: before, timeout: 0.3) else { return "not verified" }
            copy("Junior's newer copy")   // lands between the verified wait and the read
            return gate.ownString()
        }
        let keptAfterRead = pb.string(forType: .string) == "Junior's newer copy" && pb.pasteboardItems?.count == 1
        record("Pasteboard newer copy kept (Sol #3)", duringSettle == .clipboardChanged && keptAfterSettle && beforeRead == nil && keptAfterRead,
               "copy during the settle: \(duringSettle), kept: \(keptAfterSettle); copy before the read: \(beforeRead ?? "nil read"), kept: \(keptAfterRead)")

        // Sol #4: the restore runs when the body throws, when its task is cancelled mid-body and when it is cancelled
        // while queued; waitUntilIdle returns at once when idle and otherwise only after every queued transaction restored.
        struct Thrown: Error {}
        original = fill()
        _ = try? await gate.transaction { () throws -> Void in
            gate.write("temporary text")
            throw Thrown()
        }
        let afterThrow = contents() == original
        let cancelStart = Date()
        let running = Task { @MainActor in
            try await gate.transaction {
                gate.write("dictated text")
                try await Task.sleep(for: .seconds(5))
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        running.cancel()
        _ = await running.result
        let afterCancel = contents() == original && Date().timeIntervalSince(cancelStart) < 1
        let holder = Task { @MainActor in
            await gate.transaction {
                gate.write("first")
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let queued = Task { @MainActor in
            await gate.transaction { () -> Bool in
                if !Task.isCancelled { gate.write("second") }   // what a caller does with a cancelled turn
                return Task.isCancelled
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        let queuedSawCancel = await queued.value
        await holder.value
        let afterQueuedCancel = contents() == original && queuedSawCancel
        let idleStart = Date()
        await gate.waitUntilIdle()
        let idleAtOnce = Date().timeIntervalSince(idleStart) < 0.05
        _ = Task { @MainActor in
            await gate.transaction {
                gate.write("a")
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        _ = Task { @MainActor in
            await gate.transaction {
                gate.write("b")
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let drainStart = Date()
        await gate.waitUntilIdle()
        let drained = Date().timeIntervalSince(drainStart)
        let restoredAtIdle = contents() == original
        record("Pasteboard throw/cancel/idle (Sol #4)",
               afterThrow && afterCancel && afterQueuedCancel && idleAtOnce && restoredAtIdle && drained >= 0.2,
               "restored after throw: \(afterThrow), after cancel mid-body: \(afterCancel), after cancel while queued: \(afterQueuedCancel); idle wait \(idleAtOnce ? "immediate" : "slow") when idle, \(Int(drained * 1000)) ms with two queued, original back at idle: \(restoredAtIdle)")

        // Sol #21: Junior copies after the snapshot, before the body's first change (injected at the body's start, which
        // is all the gate can see of it). The restore must bring back his copy, for a write and for a Copy press alike.
        _ = fill()
        await gate.transaction {
            copy("Junior's copy before the write")
            gate.write("dictated text")
        }
        let keptBeforeWrite = pb.string(forType: .string) == "Junior's copy before the write" && pb.pasteboardItems?.count == 1
        _ = fill()
        let copiedAfter = await gate.transaction { () -> TextCapture.Copied in
            copy("Junior's copy before the Copy press")
            guard let before = gate.prepareToChange() else { return .nothing }   // what copySelection does before the press
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { copy("copied by the app") }
            return await TextCapture.readCopy(gate: gate, before: before)
        }
        let keptBeforeCopy = pb.string(forType: .string) == "Junior's copy before the Copy press" && pb.pasteboardItems?.count == 1
        record("Pasteboard early copy kept (Sol #21)",keptBeforeWrite && copiedAfter == .text("copied by the app") && keptBeforeCopy,
               "his copy is back after the write: \(keptBeforeWrite); after the Copy press: \(keptBeforeCopy) (read \(copiedAfter))")

        // Sol #22: a busy app answers Copy late. At 700 ms it is still read; inside the 1 s grace after that it is not
        // read but restored over; with no answer the transaction ends after 2 s. The original is back each time, also
        // after waiting past the moment the late copy lands.
        original = fill()
        func lateCopy(after delay: Double?) async -> (TextCapture.Copied, Int, Bool) {
            let start = Date()
            let result = await gate.transaction { () -> TextCapture.Copied in
                guard let before = gate.prepareToChange() else { return .nothing }
                if let delay { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { copy("copied late by the app") } }
                return await TextCapture.readCopy(gate: gate, before: before)
            }
            let took = Int(Date().timeIntervalSince(start) * 1000)
            try? await Task.sleep(for: .milliseconds(700))   // past the late copy, had the transaction already ended
            return (result, took, contents() == original)
        }
        let at700 = await lateCopy(after: 0.7), at1500 = await lateCopy(after: 1.5), never = await lateCopy(after: nil)
        record("Pasteboard late Copy (Sol #22)",
               at700.0 == .text("copied late by the app") && at700.2 && at1500.0 == .nothing && at1500.1 >= 1500 && at1500.2
                   && never.0 == .nothing && (1950...2500).contains(never.1) && never.2,
               "copy at 700 ms: \(at700.0) in \(at700.1) ms, original back: \(at700.2); at 1.5 s: \(at1500.0) in \(at1500.1) ms, original back: \(at1500.2); none: \(never.0) in \(never.1) ms, original back: \(never.2)")

        // Sol #20: quitting. Shutdown refuses every later write (an Inserter body then reports a failed insert, never
        // pastes), waits for the running paste to restore, and returns with the original clipboard; the queue then
        // drains without touching it. A body that never ends is restored for after the grace.
        original = fill()
        let quitting = PasteboardGate(pasteboard: pb)
        let active = Task { @MainActor in
            await quitting.transaction { () -> Bool in
                guard quitting.write("active paste") != nil else { return false }
                try? await Task.sleep(for: .milliseconds(300))   // its restore wait
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let queuedPastes = (0..<8).map { n in
            Task { @MainActor in
                await quitting.transaction { () -> Bool in
                    guard quitting.write("queued paste \(n)") != nil else { return false }   // "Talk & Read is quitting"
                    try? await Task.sleep(for: .milliseconds(500))
                    return true
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let quitStart = Date()
        await quitting.shutdown(grace: 3)
        let quitTook = Int(Date().timeIntervalSince(quitStart) * 1000)
        let atReturn = contents() == original
        var queuedPasted = 0
        for task in queuedPastes { if await task.value { queuedPasted += 1 } }
        let activePasted = await active.value
        let lateWrite = await quitting.transaction { quitting.write("after shutdown") }
        let afterDrain = contents() == original
        record("Pasteboard quit, queued (Sol #20)",
               activePasted && atReturn && afterDrain && queuedPasted == 0 && lateWrite == nil && (200..<1000).contains(quitTook),
               "returned after \(quitTook) ms (the running paste restored), original at return: \(atReturn), after the queue drained: \(afterDrain); running paste done: \(activePasted), \(queuedPasted)/\(queuedPastes.count) queued pastes written, write after shutdown refused: \(lateWrite == nil)")

        original = fill()
        let hungGate = PasteboardGate(pasteboard: pb)
        let hung = Task { @MainActor in
            await hungGate.transaction {
                hungGate.write("hung paste")
                try? await Task.sleep(for: .seconds(30))
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let hungStart = Date()
        await hungGate.shutdown(grace: 0.5)
        let hungTook = Int(Date().timeIntervalSince(hungStart) * 1000)
        let forced = contents() == original
        hung.cancel()
        await hung.value
        let afterHungEnds = contents() == original
        record("Pasteboard quit, hung body (Sol #20)",forced && afterHungEnds && (450...1000).contains(hungTook),
               "returned after \(hungTook) ms (grace 500) with the original restored: \(forced); still original once the body ended: \(afterHungEnds)")
    }

    // MARK: Screenshot OCR (R12) and the OCR selection-colour anchor (R6, R7d), headless

    private func screenshotTextCheck() async {
        let text = "Screenshot to listen reads the text inside a dragged region of the screen. The words come back in reading order, one line after another, ready for the voice."
        let rendered = SelfTestWindow.render(text, width: 700, fontSize: 22)
        let read = await ScreenshotCapture.recognize(rendered.image) ?? ""
        let expected = TextKit.tokenize(text).map { $0.text.lowercased() }
        let got = TextKit.tokenize(read).map { $0.text.lowercased() }
        let common = Self.lcs(expected, got)
        record("Screenshot OCR text", Double(common) / Double(expected.count) >= 0.95,
               "\(common)/\(expected.count) words in reading order from a rendered 700x\(rendered.image.height) image")
    }

    private func ocrHighlightCheck() async {
        let text = SelfTestWindow.ocrText as NSString
        let second = text.range(of: SelfTestWindow.ocrSentence, options: .backwards)
        let first = text.range(of: SelfTestWindow.ocrSentence)
        let rendered = SelfTestWindow.render(SelfTestWindow.ocrText, width: 900, fontSize: 22, highlight: second)
        guard let words = try? await OCRLocator.recognizeWords(rendered.image) else {
            record("OCR selection colour", false, "Vision failed on the rendered image")
            return
        }
        let size = CGSize(width: rendered.image.width, height: rendered.image.height)
        func copy(of word: OCRLocator.Word) -> Int? {   // 1 or 2: which copy of the sentence the recognised word sits in
            let centre = CGPoint(x: word.box.midX * size.width, y: (1 - word.box.midY) * size.height)
            for (n, range) in [(1, first), (2, second)] {
                for token in TextKit.tokenize(SelfTestWindow.ocrSentence)
                where rendered.rect(SelfTestWindow.ns(token.range, plus: range.location)).insetBy(dx: -2, dy: -2).contains(centre) { return n }
            }
            return nil
        }
        let copies = words.map(copy)
        let secondWords = copies.filter { $0 == 2 }.count
        let secondLit = zip(words, copies).filter { $0.0.highlighted && $0.1 == 2 }.count
        let firstLit = zip(words, copies).filter { $0.0.highlighted && $0.1 == 1 }.count
        record("OCR selection colour", secondWords > 0 && Double(secondLit) / Double(secondWords) >= 0.9 && firstLit == 0,
               "highlighted: \(secondLit)/\(secondWords) words of the selected copy, \(firstLit) of the other")
        let highlighted = Set(words.indices.filter { words[$0].highlighted })
        let map = NodeAlignment.best(words.map { $0.text.lowercased() }, TextKit.tokenize(SelfTestWindow.ocrSentence).map { $0.text.lowercased() },
                                     from: 0, prefer: highlighted)
        let onSecond = map.values.filter { copies[$0] == 2 }.count, onFirst = map.values.filter { copies[$0] == 1 }.count
        record("OCR alignment prefers selection", !map.isEmpty && onFirst == 0,
               "NodeAlignment.best placed \(onSecond) words on the selected copy, \(onFirst) on the other")
    }

    static func lcs(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal + 1 : max(row[j + 1], row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: The test window (R4, R6, R7c, R7d)

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    final class CopyForwarder: NSObject {
        var provide: (@MainActor () async -> String?)?
        let pasteboard: NSPasteboard
        init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
        /// Edit ▸ Copy of the test app: writes the pane's selection to the private test pasteboard the client reads.
        @objc func copy(_ sender: Any?) {
            let provide = provide, pasteboard = pasteboard
            Task { @MainActor in
                guard let text = await provide?() else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    private func windowChecks(on screen: NSScreen) async {
        let directory = URL(fileURLWithPath: "/private/tmp/talkread-wp4-selftest-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 960))
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 1000, width: 1100, height: 960)
        let window = Panel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.setFrame(frame, display: false)   // a titled panel's init moves a frame on a second screen onto the main one
        window.title = "Talk & Read self-test"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = content

        // Text pane: a paragraph with the phrase twice.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 20, y: 770, width: 1060, height: 170)
        let textView = scroll.documentView as! NSTextView
        textView.font = .systemFont(ofSize: 17)
        textView.string = SelfTestWindow.textParagraph
        textView.isEditable = false
        content.addSubview(scroll)

        // Web pane: the same paragraph in two <p>s.
        let web = WKWebView(frame: NSRect(x: 20, y: 580, width: 1060, height: 170))
        web.navigationDelegate = self
        content.addSubview(web)

        // PDF pane: two pages, the phrase on both.
        let pdfURL = directory.appendingPathComponent("selftest.pdf")
        Self.writePDF(to: pdfURL)
        let pdfView = PDFView(frame: NSRect(x: 20, y: 130, width: 1060, height: 430))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = PDFDocument(url: pdfURL)
        window.representedURL = pdfURL   // AXDocument, which PDFLocator opens
        content.addSubview(pdfView)

        // OCR pane: the sentence twice in a bitmap (no AX text), the selection colour behind the second copy.
        let ocr = SelfTestWindow.ocrText as NSString
        let ocrSecond = ocr.range(of: SelfTestWindow.ocrSentence, options: .backwards), ocrFirst = ocr.range(of: SelfTestWindow.ocrSentence)
        let rendered = SelfTestWindow.render(SelfTestWindow.ocrText, width: 1060, fontSize: 22, highlight: ocrSecond)
        let imageView = NSImageView(frame: NSRect(x: 20, y: 20, width: CGFloat(rendered.image.width), height: CGFloat(rendered.image.height)))
        imageView.image = NSImage(cgImage: rendered.image, size: imageView.frame.size)
        imageView.imageScaling = .scaleNone
        content.addSubview(imageView)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        let forwarder = CopyForwarder(pasteboard: pasteboard)
        let menu = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(CopyForwarder.copy(_:)), keyEquivalent: "c")
        copyItem.target = forwarder
        edit.addItem(copyItem)
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded = done
            web.loadHTMLString("<html><body style=\"margin:12px;font:17px -apple-system;background:#fff;color:#000\"><p id=\"a\">\(SelfTestWindow.webParagraph)</p><p id=\"b\">\(SelfTestWindow.webParagraph)</p></body></html>", baseURL: nil)
        }
        guard window.screen == screen, screen.frame.contains(window.frame) else {
            record("Test window panes", nil, "not run: the window could not be placed on \(screen.localizedName) (frame \(window.frame))")
            return
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close(); NSApp.mainMenu = nil }
        try? await Task.sleep(for: .milliseconds(500))

        func toScreen(_ view: NSView, _ rect: CGRect) -> CGRect { window.convertToScreen(view.convert(rect, to: nil)) }
        let text = SelfTestWindow.textParagraph as NSString
        let tokens = TextKit.tokenize(SelfTestWindow.phrase)
        func clearSelections() async {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            pdfView.clearSelection()
            _ = try? await web.evaluateJavaScript("getSelection().removeAllRanges(); 1")
        }

        // NSTextView: AX selection, direct AXBoundsForRange.
        await clearSelections()
        let textSecond = text.range(of: SelfTestWindow.phrase, options: .backwards), textFirst = text.range(of: SelfTestWindow.phrase)
        textView.setSelectedRange(textSecond)
        window.makeFirstResponder(textView)
        func glyphRect(_ range: NSRange) -> CGRect {
            let layout = textView.layoutManager!
            let r = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: textView.textContainer!)
            return toScreen(textView, r.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
        }
        let textTruth = tokens.map { glyphRect(SelfTestWindow.ns($0.range, plus: textSecond.location)) }
        await pane("NSTextView", "text", expected: SelfTestWindow.phrase, truth: textTruth,
                   first: tokens.map { glyphRect(SelfTestWindow.ns($0.range, plus: textFirst.location)) })

        // WKWebView: no AX selection, so Edit ▸ Copy through AX; node map anchored on the selection's bounds.
        await clearSelections()
        let start = (SelfTestWindow.webParagraph as NSString).range(of: SelfTestWindow.phrase).location
        _ = try? await web.evaluateJavaScript("var t=document.getElementById('b').firstChild, r=document.createRange(); r.setStart(t,\(start)); r.setEnd(t,\(start + SelfTestWindow.phrase.utf16.count)); getSelection().removeAllRanges(); getSelection().addRange(r); 1")
        window.makeFirstResponder(web)
        forwarder.provide = { try? await web.evaluateJavaScript("getSelection().toString()") as? String }
        func webRects(_ id: String) async -> [CGRect] {
            let ranges = tokens.map { "[\($0.range.lowerBound + start),\($0.range.upperBound + start)]" }.joined(separator: ",")
            let js = "(function(){var t=document.getElementById('\(id)').firstChild;return [\(ranges)].map(function(x){var r=document.createRange();r.setStart(t,x[0]);r.setEnd(t,x[1]);var b=r.getBoundingClientRect();return [b.left,b.top,b.width,b.height];});})()"
            let rows = (try? await web.evaluateJavaScript(js)) as? [[Double]] ?? []
            return rows.map { b in
                let r = CGRect(x: b[0], y: web.isFlipped ? b[1] : web.bounds.height - b[1] - b[3], width: b[2], height: b[3])
                return toScreen(web, r)
            }
        }
        await pane("WKWebView", "web", expected: SelfTestWindow.phrase, truth: await webRects("b"), first: await webRects("a"))

        // PDFView: PDFKit's page text holds the selection; page 2 must win (R7c).
        await clearSelections()
        guard let document = pdfView.document, let page1 = document.page(at: 0), let page2 = document.page(at: 1),
              let string1 = page1.string as NSString?, let string2 = page2.string as NSString? else {
            record("PDFView", false, "the generated PDF did not load")
            return
        }
        let pdfSecond = string2.range(of: SelfTestWindow.phrase), pdfFirst = string1.range(of: SelfTestWindow.phrase)
        pdfView.setCurrentSelection(page2.selection(for: pdfSecond), animate: false)
        window.makeFirstResponder(pdfView)
        forwarder.provide = { pdfView.currentSelection?.string }
        func pdfRect(_ page: PDFPage, _ range: NSRange) -> CGRect {
            toScreen(pdfView, pdfView.convert(page.selection(for: range)?.bounds(for: page) ?? .zero, from: page))
        }
        let pdfTruth = tokens.map { pdfRect(page2, SelfTestWindow.ns($0.range, plus: pdfSecond.location)) }
        let pdfFirstRects = tokens.map { pdfRect(page1, SelfTestWindow.ns($0.range, plus: pdfFirst.location)) }
        if let out = await pane("PDFView", "pdf", expected: SelfTestWindow.phrase, truth: pdfTruth, first: pdfFirstRects) {
            for (key, name) in [("pdfAnchored", "PDFLocator anchored (page 2)"), ("pdfUnanchored", "PDFLocator, no page context")] {
                let rects = Self.rects(out[key])
                let (ok, onFirst) = Self.score(rects, truth: pdfTruth, first: pdfFirstRects)
                let shown = rects.compactMap { $0 }.count
                let pass = key == "pdfAnchored" ? ok * 100 >= 95 * tokens.count && onFirst == 0 : shown == 0 || (ok == shown && onFirst == 0)
                record(name, pass, "\(ok)/\(tokens.count) on page 2, \(onFirst) on page 1, \(shown) shown (anchor \(out["pdfAnchor"] as? String ?? "none"))")
            }
        }

        // Sol #13: page 3 carries /Rotate 90; PDFLocator's boxes must land on PDFKit's own (rotated) glyph rects.
        await clearSelections()
        if let page3 = document.page(at: 2), let string3 = page3.string as NSString? {
            let turned = string3.range(of: SelfTestWindow.turned), turnedTokens = TextKit.tokenize(SelfTestWindow.turned)
            pdfView.go(to: page3)
            pdfView.setCurrentSelection(page3.selection(for: turned), animate: false)
            let turnedTruth = turnedTokens.map { pdfRect(page3, SelfTestWindow.ns($0.range, plus: turned.location)) }
            if let out = await pane("PDFView rotated page", "pdf", expected: SelfTestWindow.turned, truth: turnedTruth, first: []) {
                let rects = Self.rects(out["pdfAnchored"])
                let ok = Self.score(rects, truth: turnedTruth, first: []).ok
                record("PDFLocator rotated page (Sol #13)", page3.rotation == 90 && ok * 100 >= 95 * turnedTokens.count,
                       "page rotation \(page3.rotation): \(ok)/\(turnedTokens.count) boxes inside PDFKit's glyph rects (anchor \(out["pdfAnchor"] as? String ?? "none"))")
            }
        }

        // OCR pane (R6): rendered text, located by Vision on a ScreenCaptureKit image of this window.
        await clearSelections()
        window.makeFirstResponder(nil)
        forwarder.provide = { SelfTestWindow.ocrSentence }
        let sentenceTokens = TextKit.tokenize(SelfTestWindow.ocrSentence)
        func imageRect(_ range: NSRange) -> CGRect {
            let r = rendered.rect(range)
            return toScreen(imageView, CGRect(x: r.minX, y: imageView.bounds.height - r.maxY, width: r.width, height: r.height))
        }
        let ocrOut = await pane("Rendered text (OCR)", "ocr", expected: SelfTestWindow.ocrSentence,
                                truth: sentenceTokens.map { imageRect(SelfTestWindow.ns($0.range, plus: ocrSecond.location)) },
                                first: sentenceTokens.map { imageRect(SelfTestWindow.ns($0.range, plus: ocrFirst.location)) },
                                tolerance: 4, needed: 0.9)
        if let stale = ocrOut?["ocrStale"] as? String {   // the pane above then proves the fresh recognition boxes the words
            record("OCR stale result discarded (Sol #11)", stale == "discarded 0 shown",
                   "a scroll during the first recognition: its result \(stale); \(ocrOut?["ocr"] as? String ?? "")")
        }

        // R7b, the no-selection order. The test window is never key, so nothing in it has focus: the copy step finds
        // nothing (Copy answers with no selection), the caret step has no focused element, and the clipboard is read.
        await clearSelections()
        forwarder.provide = { nil }
        pasteboard.clearContents()
        pasteboard.setString("Text already on the clipboard.", forType: .string)
        let fromClipboard = await client("capture")
        let concealed = NSPasteboardItem()
        concealed.setString("a copied password", forType: .string)
        concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([concealed])
        let fromConcealed = await client("capture")
        pasteboard.clearContents()
        let fromNothing = await client("capture")
        record("No selection: clipboard, then nothing",
               fromClipboard?["source"] as? String == "clipboard" && fromClipboard?["text"] as? String == "Text already on the clipboard."
                   && fromConcealed?["error"] as? String == "no capture" && fromNothing?["error"] as? String == "no capture",
               "clipboard text read as source=\(fromClipboard?["source"] as? String ?? "nil"); a concealed clipboard item and an empty clipboard give no capture (\"Select some text first\")")
        // Caret to end, on the text view's element (what step 3 does with the focused element).
        textView.setSelectedRange(NSRange(location: textSecond.location, length: 0))
        try? await Task.sleep(for: .milliseconds(200))
        let caret = await client("caret")
        let expectedTail = text.substring(from: textSecond.location)
        record("Caret to end", caret?["source"] as? String == "cursor" && caret?["text"] as? String == expectedTail
                   && (caret?["selectionStart"] as? Int) == textSecond.location,
               "source=\(caret?["source"] as? String ?? "nil") selectionStart=\(caret?["selectionStart"] as? Int ?? -1) (caret at \(textSecond.location)), \(TextKit.tokenize(caret?["text"] as? String ?? "").count) words to the end")

        // Terminal-style (H3): monospaced light-on-dark lines with scrollback, scrolled to the end, read the way
        // Terminal.app's AXTextArea is (direct AXBoundsForRange). The phrase also sits in the scrolled-away history,
        // which must never be boxed.
        let history = (1...120).map { "user@mac ~ % echo line \($0)" }.joined(separator: "\n")
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .black
        textView.textColor = .white
        textView.string = "\(SelfTestWindow.phrase)\n\(history)\n\(SelfTestWindow.phrase)\nuser@mac ~ % "
        textView.scrollToEndOfDocument(nil)
        let terminal = textView.string as NSString
        let terminalLast = terminal.range(of: SelfTestWindow.phrase, options: .backwards), terminalFirst = terminal.range(of: SelfTestWindow.phrase)
        textView.setSelectedRange(terminalLast)
        window.makeFirstResponder(textView)
        await pane("Terminal-style text view", "text", expected: SelfTestWindow.phrase,
                   truth: tokens.map { glyphRect(SelfTestWindow.ns($0.range, plus: terminalLast.location)) },
                   first: tokens.map { glyphRect(SelfTestWindow.ns($0.range, plus: terminalFirst.location)) })

        await wakeCheck("E8 wake, app with native text", bare: false)
        await overlayCheck(window: window, screen: screen, word: textTruth[0], sentence: textTruth)
        record("Test window never key", !window.isKeyWindow && !window.isMainWindow, "shown with orderFrontRegardless on \(screen.localizedName)")
    }

    /// Runs the client on one pane and scores its rects against the view's own glyph rects. Returns the client output.
    @discardableResult
    private func pane(_ name: String, _ pane: String, expected: String, truth: [CGRect], first: [CGRect],
                      tolerance: CGFloat? = nil, needed: Double = 0.95) async -> [String: Any]? {
        try? await Task.sleep(for: .milliseconds(300))   // let AX see the new selection
        guard let out = await client(pane) else {
            record(name, false, "client produced no output")
            return nil
        }
        if let skipped = out["skipped"] as? String {
            record(name, nil, "skipped (\(skipped))")
            return out
        }
        let text = out["text"] as? String
        let rects = Self.rects(out["rects"])
        let (ok, onFirst) = Self.score(rects, truth: truth, first: first, tolerance: tolerance)
        let paths = Set((out["paths"] as? [String]) ?? []).sorted().joined(separator: ",")
        let pass = text == expected && rects.count == truth.count && Double(ok) >= needed * Double(truth.count) && onFirst == 0
        if !pass { FileHandle.standardError.write(Data("  client: element=\(out["element"] ?? "-") nodeMap=\(out["nodeMap"] ?? "-") ocr=\(out["ocr"] ?? "-") rects=\(rects.prefix(3)) truth=\(truth.prefix(3))\n".utf8)) }
        record(name, pass, "source=\(out["source"] as? String ?? "?") path=\(paths) \(ok)/\(truth.count) boxed on the selected copy\(tolerance.map { " (centre within \(Int($0)) pt)" } ?? " (centre inside glyph rect)"), \(onFirst) on the other copy\(text == expected ? "" : "; captured text was \"\(text ?? "nil")\"")")
        return out
    }

    /// E8, read from a child process through AX. `bare`: this host has no window, so it exposes no text and must be woken
    /// (ledger set, AXEnhancedUserInterface on) and put back by `restore`. Otherwise the test window exposes text and the
    /// app must never be woken. Either way a real `TextCapture.capture` leaves the attribute as it found it.
    private func wakeCheck(_ name: String, bare: Bool) async {
        guard let out = await client("wake") else { record(name, false, "client produced no output"); return }
        func flag(_ key: String) -> Bool { out[key] as? Bool ?? false }
        let before = flag("before")
        let expected = bare ? (out["windows"] as? Int == 0 && flag("woken") && flag("during") && !before)
                            : (out["windows"] as? Int ?? 0 > 0 && !flag("woken") && flag("during") == before)
        let wakeMs = out["wakeMs"] as? Int ?? .max   // the probe is time-bounded (250 ms, plus slack)
        let pass = expected && wakeMs < 600 && flag("restored") == before && flag("afterCapture") == before && !flag("leftWoken")
        record(name, pass, "wake \(wakeMs) ms, windows \(out["windows"] ?? "?"): before \(before), woken \(flag("woken")), during \(flag("during")), after restore \(flag("restored")), after capture \(flag("afterCapture")), ledger left \(flag("leftWoken"))")
    }

    private func client(_ pane: String) async -> [String: Any]? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--selftest-window", "--client", String(getpid()), pane, pasteboardName]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        // Off the main thread: this process must keep answering the client's AX requests while it waits.
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return object
    }

    static func microseconds(_ n: Int, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<n { body() }
        let each = (ContinuousClock.now - start) / n
        return Double(each.components.seconds) * 1e6 + Double(each.components.attoseconds) / 1e12
    }

    static func rects(_ value: Any?) -> [CGRect?] {
        ((value as? [Any]) ?? []).map { ($0 as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
    }

    /// ok: rects whose centre is inside the truth rect (or within `tolerance` of its centre); onFirst: rects on the other copy.
    static func score(_ rects: [CGRect?], truth: [CGRect], first: [CGRect], tolerance: CGFloat? = nil) -> (ok: Int, onFirst: Int) {
        var ok = 0, onFirst = 0
        for (i, rect) in rects.enumerated() {
            guard let rect, i < truth.count else { continue }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            if let tolerance {
                if abs(c.x - truth[i].midX) <= tolerance, abs(c.y - truth[i].midY) <= tolerance { ok += 1 }
            } else if truth[i].insetBy(dx: -1, dy: -1).contains(c) {
                ok += 1
            }
            if first.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(c) }) { onFirst += 1 }
        }
        return (ok, onFirst)
    }

    private static func writePDF(to url: URL) {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 700, height: 100)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
        NSGraphicsContext.saveGraphicsState()
        for n in 1...2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(n). \(SelfTestWindow.phrase)" as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            context.endPDFPage()
        }
        var turnedBox = CGRect(x: 0, y: 0, width: 300, height: 60)   // a short page, shown 60 wide and 300 tall
        context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &turnedBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (SelfTestWindow.turned as NSString).draw(at: CGPoint(x: 16, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        context.endPDFPage()
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { return }
        document.page(at: 2)?.rotation = 90   // stored as /Rotate, which PDFLocator reads back from the file
        document.write(to: url)
    }

    // MARK: PDF page numbering (Sol #12), headless

    /// AXPageIndex base from viewer metadata: Sol's case (a zero-based viewer exposing only its second page) must give 0,
    /// the old guess gave 1; no metadata and a partial page set hides.
    private func pageBaseCheck() {
        let cases: [(descriptions: [Int: String?], count: Int, expected: Int?)] = [
            ([1: "Page 2"], 5, 0), ([2: "Page 2"], 5, 1), ([1: "Seite 2 "], 5, 0), ([1: nil], 5, nil),
            ([0: nil, 1: nil, 2: nil], 3, 0), ([1: nil, 2: nil, 3: nil], 3, 1), ([1: "Page 2", 3: "Page 3"], 5, nil),
            ([4: "Page iv"], 9, nil), ([0: "Page 1", 1: "Page 2", 2: "Page 3"], 3, 0),
        ]
        let wrong = cases.filter { PDFLocator.base(descriptions: $0.descriptions, pageCount: $0.count) != $0.expected }
        record("PDF page base from metadata (Sol #12)", wrong.isEmpty,
               "\(cases.count - wrong.count)/\(cases.count) cases; only-page-2 exposed reads as zero-based, no metadata on a partial set hides\(wrong.isEmpty ? "" : "; wrong: \(wrong.map { "\($0.descriptions)" })")")
    }

    // MARK: Overlay (R4: never takes clicks, never key; no panel while idle; H2: pinned to the window being read)

    private func overlayCheck(window: NSWindow, screen: NSScreen, word: CGRect, sentence: [CGRect]) async {
        let overlay = Overlay(style: Overlay.Style())
        overlay.source = CGWindowID(window.windowNumber)
        var followed = false, above = false
        for _ in 0..<2 where !above {   // two reading ticks: an order shows once the run loop has committed it
            followed = overlay.follow()
            try? await Task.sleep(for: .milliseconds(60))
            let order = WindowPin.snapshot(above: CGWindowID(window.windowNumber)).map(\.id)
            above = overlay.panel.map { order.count >= 2 && order[order.count - 2] == CGWindowID($0.windowNumber) } ?? false
        }
        overlay.show(word: word, sentence: sentence)
        let panel = overlay.panel
        let flags = panel.map(Self.overlayFlags) ?? false
        let drawn = panel.map { overlay.wordLayer.frame.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY).insetBy(dx: 2, dy: 1) }
        let placed = drawn.map { abs($0.midX - word.midX) < 0.5 && abs($0.midY - word.midY) < 0.5 } ?? false
        try? await Task.sleep(for: .milliseconds(400))
        overlay.hide()
        record("Overlay panel", followed && flags && above && placed && overlay.panel == nil,
               "on \(screen.localizedName), directly above the test window: \(above); click-through, never key/main, nonactivating, the window's level, one Space: \(flags); box on the word: \(placed); closed at hide: \(overlay.panel == nil)")
    }

    static func overlayFlags(_ p: NSPanel) -> Bool {
        p.ignoresMouseEvents && !p.canBecomeKey && !p.canBecomeMain && !p.isKeyWindow && p.styleMask.contains(.nonactivatingPanel)
            && p.level == .normal && !p.collectionBehavior.contains(.canJoinAllSpaces)
            && p.collectionBehavior.contains([.transient, .fullScreenAuxiliary, .ignoresCycle])
    }

    // MARK: Window pin (H2), headless: recorded window-server snapshots

    /// Read-only snapshot, 23 Oct: Claude full screen (667) under its own title strip (669) and other apps' higher-layer
    /// windows; 690 is Codex's window on another Space, which the window server leaves out (listing everything else).
    /// Our panel (9000) and another app's window (2741) are placed into it as the live check saw them.
    private func pinPlacementCheck() {
        let claude: pid_t = 6134
        let main = WindowInfo(id: 667, pid: claude, bounds: CGRect(x: 0, y: 0, width: 2304, height: 1296))
        let strip = WindowInfo(id: 669, pid: claude, bounds: CGRect(x: 0, y: -32, width: 2304, height: 32))
        let higher = [WindowInfo(id: 2562, pid: 30286, layer: 27, bounds: CGRect(x: 1820, y: 1168, width: 94, height: 38)),
                      WindowInfo(id: 346, pid: 432, layer: 24, bounds: CGRect(x: -2304, y: 0, width: 2304, height: 30)),
                      WindowInfo(id: 1439, pid: 30347, layer: 5, bounds: CGRect(x: 2272, y: 50, width: 35, height: 1202)),
                      WindowInfo(id: 2563, pid: 30286, layer: 1, bounds: CGRect(x: 324, y: 1101, width: 1580, height: 163))]
        let panel = WindowInfo(id: 9000, pid: getpid(), bounds: main.bounds)
        let cover = WindowInfo(id: 2741, pid: 777, bounds: CGRect(x: 300, y: 200, width: 800, height: 600))
        let moved = WindowInfo(id: 667, pid: claude, bounds: CGRect(x: 100, y: 40, width: 1600, height: 1000))
        let elsewhere = [WindowInfo(id: 347, pid: 432, layer: -2147483602, bounds: CGRect(x: -2304, y: 0, width: 2304, height: 110)),
                         WindowInfo(id: 348, pid: 657, layer: -2147483603, bounds: CGRect(x: -2304, y: 0, width: 2304, height: 1296)),
                         WindowInfo(id: 1271, pid: 656, layer: -2147483625, bounds: CGRect(x: 0, y: 0, width: 2304, height: 1296)),
                         WindowInfo(id: 336, pid: 432, layer: -2147483626, bounds: CGRect(x: -2304, y: 0, width: 2304, height: 1296))]
        func shown(_ order: WindowPin.PanelOrder, _ w: WindowInfo = main) -> WindowPin.Placement { .shown(bounds: w.bounds, layer: 0, panel: order) }
        let cases: [(name: String, list: [WindowInfo], source: CGWindowID, expected: WindowPin.Placement)] = [
            ("no panel, or the window raised over it", higher + [strip, main], 667, shown(.missing)),
            ("directly above", higher + [strip, panel, main], 667, shown(.directlyAbove)),
            ("over the app's own title strip", higher + [panel, strip, main], 667, shown(.separated)),
            ("another app's window covers it", higher + [cover, panel, main], 667, shown(.directlyAbove)),
            ("our app raised it over another app", higher + [panel, cover, main], 667, shown(.separated)),
            ("window moved", higher + [panel, moved], 667, shown(.directlyAbove, moved)),
            ("other Space, minimised or hidden", elsewhere, 690, .hidden),
            ("closed (empty list)", [], 667, .hidden),
            ("fully transparent", higher + [WindowInfo(id: 667, pid: claude, bounds: main.bounds, alpha: 0)], 667, .hidden),
        ]
        let wrong = cases.filter { WindowPin.placement($0.list, source: $0.source, panel: 9000) != $0.expected }.map(\.name)

        // Parsing a CGWindowList entry; kCGWindowIsOnscreen is absent for an off-screen window.
        let entry: [String: Any] = [kCGWindowNumber as String: NSNumber(value: 667), kCGWindowOwnerPID as String: NSNumber(value: claude),
                                    kCGWindowLayer as String: NSNumber(value: 0), kCGWindowAlpha as String: NSNumber(value: 1),
                                    kCGWindowBounds as String: main.bounds.dictionaryRepresentation, kCGWindowIsOnscreen as String: kCFBooleanTrue!]
        var offEntry = entry
        offEntry[kCGWindowIsOnscreen as String] = nil
        let parsed = WindowInfo(entry) == main && WindowInfo(offEntry)?.onScreen == false

        // The window behind the capture: AX frame match, ties to the frontmost, slivers never; no frame: the frontmost.
        let back = WindowInfo(id: 700, pid: claude, bounds: CGRect(x: 200, y: 100, width: 900, height: 700))
        let onScreen = higher + [strip, main, back]
        let resolved = WindowPin.windowID(pid: claude, axFrame: main.bounds, in: onScreen) == 667
            && WindowPin.windowID(pid: claude, axFrame: CGRect(x: 201, y: 100, width: 900, height: 700), in: onScreen) == 700
            && WindowPin.windowID(pid: claude, axFrame: nil, in: onScreen) == 667
            && WindowPin.windowID(pid: claude, axFrame: main.bounds, in: [WindowInfo(id: 667, pid: claude, bounds: main.bounds, onScreen: false)]) == nil
        record("Overlay pin on recorded snapshots (H2)", wrong.isEmpty && parsed && resolved,
               "\(cases.count - wrong.count)/\(cases.count) placements (directly above, separated, missing, hidden) right; CGWindowList entry parsed: \(parsed); capture window resolved: \(resolved)\(wrong.isEmpty ? "" : "; wrong: \(wrong)")")
    }

    // MARK: Pinned overlay (H1, H2), live window server, nothing on any display

    /// A child process plays the app being read: its window sits far off every display (nothing visible anywhere, never
    /// key) and it raises, covers, moves and hides that window on command. This process pins a real Overlay to it, as
    /// the Highlighter does, and checks with window-server facts that the panel sits directly above the window, stays
    /// under a window covering it, moves with it, is closed while the window is off screen and comes back with it.
    private func pinnedOverlayCheck() async {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--selftest-window", "--client", String(getpid()), "pinsource", pasteboardName]
        let input = Pipe(), output = Pipe()
        (process.standardInput, process.standardOutput) = (input, output)
        guard (try? process.run()) != nil else { record("Pinned overlay (H2)", false, "the source process did not start"); return }
        defer { if process.isRunning { process.terminate() } }
        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        func send(_ command: String) async -> CGWindowID? {   // the reply carries the cover window's number (0: none)
            input.fileHandleForWriting.write(Data((command + "\n").utf8))
            let reply = try? await lines.next()
            try? await Task.sleep(for: .milliseconds(60))   // its order is committed after its reply
            return reply.flatMap { $0.split(separator: " ").last.flatMap { CGWindowID($0) } }
        }
        guard let first = try? await lines.next(), let sid = CGWindowID(first) else {
            record("Pinned overlay (H2)", false, "the source process reported no window")
            return
        }
        let pid = process.processIdentifier
        let axWindow = (axAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement])?.first
        let overlay = Overlay(style: Overlay.Style())
        overlay.source = WindowPin.windowID(pid: pid, axFrame: axWindow.flatMap(axFrame))
        func order() -> [CGWindowID] { WindowPin.snapshot(above: sid).map(\.id) }   // front to back, the source last
        func pinned() -> Bool {
            guard let panel = overlay.panel else { return false }
            let o = order()
            return o.count >= 2 && o.last == sid && o[o.count - 2] == CGWindowID(panel.windowNumber)
        }
        /// Two reading ticks: an order shows in the window list once the run loop has committed it.
        func follow() async -> Bool {
            var ok = false
            for _ in 0..<2 where !ok {
                guard overlay.follow() else { break }
                try? await Task.sleep(for: .milliseconds(60))
                ok = pinned()
            }
            if !ok {
                let o = WindowPin.snapshot(above: sid)
                FileHandle.standardError.write(Data("  pin: panel \(overlay.panel.map { "\($0.windowNumber) \($0.frame) level \($0.level.rawValue)" } ?? "nil"), source \(sid), order \(o.suffix(5).map { "\($0.id)/\($0.pid)/L\($0.layer)" })\n".utf8))
            }
            return ok
        }
        func sourceFrame() -> CGRect? { WindowPin.snapshot(above: sid).last.map { Locator.convert(topLeftScreenRect: $0.bounds) } }
        func box() -> CGRect? {
            guard let panel = overlay.panel, !overlay.wordLayer.isHidden else { return nil }
            return overlay.wordLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        }
        func near(_ a: CGRect?, _ b: CGRect) -> Bool { a.map { abs($0.minX - b.minX) < 0.5 && abs($0.minY - b.minY) < 0.5 && abs($0.width - b.width) < 0.5 && abs($0.height - b.height) < 0.5 } ?? false }

        var steps: [String: Bool] = [:]
        steps["resolved"] = overlay.source == sid
        steps["pinned"] = await follow() && overlay.panel.map(Self.overlayFlags) == true && overlay.panel?.frame == sourceFrame()
        guard let frame = sourceFrame() else { record("Pinned overlay (H2)", false, "the source window is not on screen"); return }
        let word = CGRect(x: frame.minX + 40, y: frame.maxY - 60, width: 80, height: 18)
        overlay.show(word: word, sentence: [word.insetBy(dx: -30, dy: 0)])
        steps["box on the word"] = near(box(), word.insetBy(dx: -2, dy: -1))

        _ = await send("raise")
        let raisedOver = !pinned()   // the window now covers the panel, as when its app is activated
        steps["window raised: back above it"] = raisedOver ? await follow() : false

        let cover = await send("cover") ?? 0
        let coverAbove = { let o = order(); return (o.firstIndex(of: cover) ?? .max) < (overlay.panel.flatMap { o.firstIndex(of: CGWindowID($0.windowNumber)) } ?? -1) }
        steps["covered: stays under the cover"] = cover != 0 ? await follow() && coverAbove() : false
        overlay.panel?.orderFrontRegardless()   // our app activated: its windows rise over the other app's
        try? await Task.sleep(for: .milliseconds(60))
        let wasOver = !coverAbove()
        steps["raised over the cover: back under it"] = wasOver ? await follow() && coverAbove() : false

        let before = box()
        _ = await send("move")
        steps["window moved: panel and box follow"] = await follow() && overlay.panel?.frame == sourceFrame()
            && near(box(), before?.offsetBy(dx: 100, dy: -40) ?? .null)

        _ = await send("hide")   // to the window server, minimised, hidden and on another Space all look like this
        let hidden = !overlay.follow() && overlay.panel == nil
        steps["window off screen: no panel"] = hidden
        _ = await send("show")
        steps["window back: new panel, word shown"] = await follow() && box() != nil

        // H1: the style option; the box stays today's default.
        let moved = word.offsetBy(dx: 100, dy: -40)
        var shapes: [String] = []
        for shape in [Overlay.Style.Shape.box, .outline, .underline] {
            overlay.style.shape = shape
            overlay.show(word: moved, sentence: [])
            let layer = overlay.wordLayer
            let ok = switch shape {
            case .box: near(box(), moved.insetBy(dx: -2, dy: -1)) && layer.backgroundColor != nil && layer.borderWidth == 1.5
            case .outline: near(box(), moved.insetBy(dx: -2, dy: -1)) && layer.backgroundColor == nil && layer.borderWidth == 2
            case .underline: near(box(), CGRect(x: moved.minX, y: moved.minY - 3, width: moved.width, height: 3)) && layer.borderWidth == 0
            }
            if ok { shapes.append(shape.rawValue) }
        }
        steps["styles box, outline, underline"] = shapes.count == 3 && Overlay.Style().shape == .box
        overlay.style.shape = .box

        // Cost per reading tick with the panel in place: the pin (one window-server query) and the drawing.
        let followUs = Self.microseconds(300) { _ = overlay.follow() }
        let showUs = Self.microseconds(300) { overlay.show(word: moved, sentence: [moved]) }

        overlay.hide()
        steps["closed at the end of the read"] = overlay.panel == nil
        _ = await send("quit")
        let failed = steps.filter { !$0.value }.keys.sorted()
        record("Pinned overlay, live window server (H2)", failed.isEmpty,
               "\(steps.count - failed.count)/\(steps.count) steps in another process's window off every display: resolved from its AX frame, directly above it, under a covering window, back above after raises, follows a move, gone while off screen, back with it\(failed.isEmpty ? "" : "; failed: \(failed)")")
        record("Overlay styles (H1)", steps["styles box, outline, underline"] == true, "drawn: \(shapes.joined(separator: ", ")); default box")
        record("Overlay tick cost", followUs + showUs < 2000,
               String(format: "pin %.0f µs, draw %.0f µs: %.2f %% of one core while reading (pin 10 Hz, draw 30 Hz), %.2f %% while paused (pin 5 Hz)", followUs, showUs, (followUs * 10 + showUs * 30) / 1e4, followUs * 5 / 1e4))
    }

    // MARK: R5, read-only node map probe on a real Chromium/Electron window

    private func chromiumProbe() async {
        let apps = ["com.google.Chrome", "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in (axAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard let run = Self.visibleTextRun(in: window) else { continue }
                // Provided text with the window for geometry; nothing is set on the app (no wake, no selection).
                let locator = Locator(capture: Capture(text: run, pid: app.processIdentifier, element: nil, window: window, selectionStart: nil, source: .provided))
                let tokens = TextKit.tokenize(run)
                let hits = tokens.filter { locator.rect(forWord: $0.range) != nil && locator.pathUsed == .nodeMap }.count
                var i = 0   // a reading tick's AX work once the map is built: one word lookup
                let lookupUs = Self.microseconds(tokens.count) { _ = locator.rect(forWord: tokens[i % tokens.count].range); i += 1 }
                record("R5 node map (\(app.localizedName ?? app.bundleIdentifier ?? "?"))", hits * 10 >= tokens.count * 9,
                       "\(hits)/\(tokens.count) words of a visible text run boxed with path=nodeMap (read-only); node map \(locator.nodeMapSummary); \(Int(lookupUs)) µs per word lookup")
                return
            }
        }
        record("R5 node map", nil, "unverified: no open Chromium/Electron window exposes a visible text run of 30+ words without being woken (read-only probe)")
    }

    /// The first AXStaticText of 30+ words, outside chrome, whose first and last words both lie inside the window and on
    /// a screen (a node can sit inside the window frame while its text is scrolled away).
    private static func visibleTextRun(in window: AXUIElement) -> String? {
        guard let windowFrame = axFrame(window) else { return nil }
        func visible(_ node: AXUIElement, _ token: Token?) -> Bool {
            guard let token, let r = axBounds(node, location: token.range.lowerBound, length: token.range.count), !r.isEmpty else { return false }
            let cocoa = Locator.convert(topLeftScreenRect: r)
            return windowFrame.contains(r) && NSScreen.screens.contains { $0.frame.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) }
        }
        var stack: [(AXUIElement, Bool)] = [(window, false)]
        var visited = 0
        while let (node, parentChrome) = stack.popLast(), visited < 8000 {
            visited += 1
            let role = axAttribute(node, kAXRoleAttribute) as? String
            let chrome = NodeAlignment.isChrome(role: role, parentChrome: parentChrome)
            if role == "AXStaticText", !chrome, let value = axAttribute(node, kAXValueAttribute) as? String {
                let tokens = TextKit.tokenize(value)
                if tokens.count >= 30, visible(node, tokens.first), visible(node, tokens.last) { return value }
            }
            if let children = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children.reversed().map { ($0, chrome) }) }
        }
        return nil
    }
}

// MARK: - Client (child process): the real capture and locator against the host's window

enum SelfTestClient {
    @MainActor static func run(host: pid_t, pane: String, pasteboard: String) async -> Int32 {
        var out: [String: Any] = ["pane": pane]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: out), let line = String(data: data, encoding: .utf8) { print(line) }
            fflush(stdout)
        }
        TextCapture.gate = PasteboardGate(pasteboard: NSPasteboard(name: NSPasteboard.Name(pasteboard)))
        if pane == "pinsource" { return await pinSource() }
        if pane == "ocr", !CGPreflightScreenCaptureAccess() {   // never prompt from a test
            out["skipped"] = "no Screen Recording"
            return 0
        }
        if pane == "caret" {   // the host's text view, its selection collapsed to a caret
            var queue = (axAttribute(AXUIElementCreateApplication(host), kAXWindowsAttribute) as? [AXUIElement]) ?? []
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if (axAttribute(element, kAXRoleAttribute) as? String) == "AXTextArea" {
                    let c = TextCapture.caretToEnd(element, pid: host, window: nil)
                    (out["source"], out["text"], out["selectionStart"]) = (c.map { "\($0.source)" }, c?.text, c?.selectionStart)
                    return 0
                }
                queue += (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            return 1
        }
        if pane == "wake" {   // E8: AXEnhancedUserInterface on the host, seen from outside, around wake / restore / capture
            let app = AXUIElementCreateApplication(host)
            func enhanced() -> Any { (axAttribute(app, "AXEnhancedUserInterface") as? Bool).map { $0 } ?? false }
            out["windows"] = (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
            out["before"] = enhanced()
            let started = ContinuousClock.now
            await AXWake.wake(app, pid: host)
            out["wakeMs"] = Int((ContinuousClock.now - started) / .milliseconds(1))
            (out["woken"], out["during"]) = (AXWake.isWoken(host), enhanced())
            AXWake.restore(host)
            out["restored"] = enhanced()
            _ = await TextCapture.capture(pid: host)
            (out["afterCapture"], out["leftWoken"]) = (enhanced(), AXWake.isWoken(host))
            return 0
        }
        guard let capture = await TextCapture.capture(pid: host) else {
            out["error"] = "no capture"
            return 1
        }
        out["source"] = "\(capture.source)"
        out["text"] = capture.text
        if pane == "capture" { return 0 }
        let tokens = TextKit.tokenize(capture.text)
        let locator = Locator(capture: capture, useOCR: pane == "ocr")
        if pane == "ocr", let first = tokens.first {
            // Sol #11: a scroll lands while the first recognition runs. Its result must be discarded, never shown.
            _ = locator.rect(forWord: first.range)   // starts the first capture
            locator.invalidate()
            var staleShown = 0
            for _ in 0..<100 where !locator.ocrSummary.contains("discarded") {
                if locator.rect(forWord: first.range) != nil { staleShown += 1 }
                try? await Task.sleep(for: .milliseconds(50))
            }
            out["ocrStale"] = "\(locator.ocrSummary.contains("discarded") ? "discarded" : "kept") \(staleShown) shown"
            // OCR answers asynchronously: wait for the fresh recognition.
            for _ in 0..<40 where locator.rect(forWord: first.range) == nil { try? await Task.sleep(for: .milliseconds(150)) }
        }
        func encode(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() }
        var rects: [Any] = [], paths: [String] = []
        for token in tokens {
            rects.append(encode(locator.rect(forWord: token.range)))
            paths.append(locator.pathUsed.rawValue)
        }
        out["rects"] = rects
        out["paths"] = paths
        out["nodeMap"] = locator.nodeMapSummary
        out["ocr"] = locator.ocrSummary
        out["element"] = capture.element.flatMap { axAttribute($0, kAXRoleAttribute) as? String } ?? "nil"
        if pane == "pdf", let window = capture.window {
            let anchor = PDFLocator.anchor(element: capture.element, selectionStart: capture.selectionStart)
            out["pdfAnchor"] = anchor.map { "page \($0.page) offset \($0.offset.map(String.init) ?? "nil")" } ?? "none"
            let anchored = PDFLocator(window: window, tokens: tokens, anchor: anchor)
            let unanchored = PDFLocator(window: window, tokens: tokens, anchor: nil)
            out["pdfAnchored"] = tokens.indices.map { encode(anchored?.rect(forTokenIndex: $0)) }
            out["pdfUnanchored"] = tokens.indices.map { encode(unanchored?.rect(forTokenIndex: $0)) }
        }
        return 0
    }

    /// H2's stand-in for the app being read: borderless windows far off every display, on every Space so they count as
    /// on screen whatever Space Junior is on, click-through and never key. Prints the window number, then obeys stdin.
    @MainActor static func pinSource() async -> Int32 {
        func window(_ frame: NSRect) -> NSPanel {
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            w.animationBehavior = .none
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            return w
        }
        let frame = NSRect(x: 30_000, y: 30_000, width: 600, height: 400)
        let source = window(frame)
        source.orderFrontRegardless()
        var cover: NSPanel?
        print(source.windowNumber)
        fflush(stdout)
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                switch line {
                case "raise", "show": source.orderFrontRegardless()
                case "cover":
                    cover = window(frame.insetBy(dx: 100, dy: 100))
                    cover?.orderFrontRegardless()
                case "move": source.setFrameOrigin(NSPoint(x: frame.minX + 100, y: frame.minY - 40))
                case "hide": source.orderOut(nil)
                default: return 0
                }
                print("ok \(cover?.windowNumber ?? 0)")
                fflush(stdout)
            }
        } catch {}
        return 0
    }
}
