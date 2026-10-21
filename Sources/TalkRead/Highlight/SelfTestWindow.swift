// `TalkRead --selftest-window` (R4, R5, R6, R7, R7c, R7d, R12). Headless first: PasteboardGate, the coordinate flip,
// screenshot OCR and the OCR selection-colour anchor on rendered bitmaps. Then, on the Prompter XL screen only, one test
// window (NSTextView, WKWebView, PDFView, rendered-text NSImageView) shown without activating the app or becoming key.
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
            app.setActivationPolicy(.accessory)
            Task { @MainActor in exit(await SelfTestHost().run()) }
        }
        app.run()
        return 1
    }

    static let phrase = "The highlight follows every spoken word without guessing."
    static let textParagraph = "Talk and Read draws a yellow box on each word as the voice reads it aloud. \(phrase) Some sentences repeat on purpose, so the locator has to choose the right copy. \(phrase) When it cannot be sure, it hides the box instead."
    static let webParagraph = "Talk and Read draws a yellow box on each word as the voice reads it aloud. \(phrase) When it cannot be sure, it hides the box instead."
    static let ocrSentence = "Reading aloud keeps the eye and the ear together on every line."
    static let ocrText = "\(ocrSentence) A different sentence sits between the two copies. \(ocrSentence)"

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

        print("\nTalk and Read --selftest-window")
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

        original = fill()
        let copied = await gate.transaction { () -> String? in
            let before = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {   // the app answering Edit ▸ Copy
                pb.clearContents()
                pb.setString("copied by the app", forType: .string)
            }
            return await gate.waitForChange(from: before, timeout: 0.3) ? pb.string(forType: .string) : nil
        }
        let start = Date()
        let changed = await gate.transaction { await gate.waitForChange(from: pb.changeCount, timeout: 0.3) }
        let waited = Date().timeIntervalSince(start)
        record("Pasteboard copy wait", copied == "copied by the app" && contents() == original && !changed && (0.28...0.6).contains(waited),
               "read \"\(copied ?? "nil")\" then restored; no change times out after \(Int(waited * 1000)) ms")
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
        window.title = "Talk and Read self-test"
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
        let pdfView = PDFView(frame: NSRect(x: 20, y: 300, width: 1060, height: 260))
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

        // OCR pane (R6): rendered text, located by Vision on a ScreenCaptureKit image of this window.
        await clearSelections()
        window.makeFirstResponder(nil)
        forwarder.provide = { SelfTestWindow.ocrSentence }
        let sentenceTokens = TextKit.tokenize(SelfTestWindow.ocrSentence)
        func imageRect(_ range: NSRange) -> CGRect {
            let r = rendered.rect(range)
            return toScreen(imageView, CGRect(x: r.minX, y: imageView.bounds.height - r.maxY, width: r.width, height: r.height))
        }
        await pane("Rendered text (OCR)", "ocr", expected: SelfTestWindow.ocrSentence,
                   truth: sentenceTokens.map { imageRect(SelfTestWindow.ns($0.range, plus: ocrSecond.location)) },
                   first: sentenceTokens.map { imageRect(SelfTestWindow.ns($0.range, plus: ocrFirst.location)) },
                   tolerance: 4, needed: 0.9)

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

        await overlayCheck(screen: screen, word: textTruth[0], sentence: textTruth)
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
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
        data.write(to: url, atomically: true)
    }

    // MARK: Overlay (R4: never takes clicks, never key; no panel while idle)

    private func overlayCheck(screen: NSScreen, word: CGRect, sentence: [CGRect]) async {
        let overlay = Overlay(style: Overlay.Style(), screens: { [screen] })
        overlay.show(word: word, sentence: sentence)
        let panels = overlay.panels
        let flags = panels.allSatisfy { p in
            p.panel.ignoresMouseEvents && !p.panel.canBecomeKey && !p.panel.canBecomeMain && p.panel.styleMask.contains(.nonactivatingPanel)
                && p.panel.level == .screenSaver && p.panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        }
        let drawn = panels.first.map { p in p.wordLayer.frame.offsetBy(dx: p.panel.frame.minX, dy: p.panel.frame.minY).insetBy(dx: 2, dy: 1) }
        let placed = drawn.map { abs($0.midX - word.midX) < 0.5 && abs($0.midY - word.midY) < 0.5 } ?? false
        try? await Task.sleep(for: .milliseconds(400))
        overlay.hide()
        try? await Task.sleep(for: .milliseconds(2300))
        record("Overlay panels", panels.count == 1 && flags && placed && overlay.panels.isEmpty,
               "\(panels.count) panel on \(screen.localizedName): click-through, never key/main, nonactivating, screenSaver level, all Spaces; box on the word: \(placed); closed 2 s after hide: \(overlay.panels.isEmpty)")
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
                record("R5 node map (\(app.localizedName ?? app.bundleIdentifier ?? "?"))", hits * 10 >= tokens.count * 9,
                       "\(hits)/\(tokens.count) words of a visible text run boxed with path=nodeMap (read-only); node map \(locator.nodeMapSummary)")
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
        guard let capture = await TextCapture.capture(pid: host) else {
            out["error"] = "no capture"
            return 1
        }
        out["source"] = "\(capture.source)"
        out["text"] = capture.text
        if pane == "capture" { return 0 }
        let tokens = TextKit.tokenize(capture.text)
        let locator = Locator(capture: capture, useOCR: pane == "ocr")
        if pane == "ocr", let first = tokens.first {   // OCR answers asynchronously: wait for the first recognition
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
}
