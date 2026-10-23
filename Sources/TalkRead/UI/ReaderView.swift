// The in-app reader: NSTextView for text kinds (word pill + sentence tint drawn behind the glyphs, click a word to read
// from it, follows the spoken word) and PDFView for PDFs (PDFSelection highlights, click to read). Owned by WP6.
import AppKit
import PDFKit
import SwiftUI
import TalkReadCore

/// Sentence and click lookups shared by the reader and the mini player.
enum ReadingText {
    /// UTF-16 range of each sentence (first word start to last word end), indexed by `Token.sentence`.
    static func sentenceRanges(_ tokens: [Token]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for t in tokens {
            if t.sentence < out.count {
                out[t.sentence] = out[t.sentence].lowerBound..<t.range.upperBound
            } else {
                while out.count < t.sentence { out.append(t.range.lowerBound..<t.range.lowerBound) }
                out.append(t.range)
            }
        }
        return out
    }

    /// The word at a UTF-16 offset, or the next one when the offset falls between words.
    static func token(at offset: Int, in tokens: [Token]) -> Int? {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].range.upperBound < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < tokens.count ? lo : tokens.indices.last
    }

    /// The previous, current and next sentence around a word, with the word's UTF-16 range inside the current one.
    static func karaoke(text: String, tokens: [Token], sentences: [Range<Int>], token: Int?) -> KaraokeLine? {
        guard let token, tokens.indices.contains(token) else { return nil }
        let ns = text as NSString
        func sentence(_ i: Int) -> (text: String, start: Int)? {
            guard sentences.indices.contains(i) else { return nil }
            let start = sentences[i].lowerBound
            let end = i + 1 < sentences.count ? sentences[i + 1].lowerBound : ns.length
            var s = ns.substring(with: NSRange(location: start, length: end - start))
            while let last = s.last, last.isWhitespace { s.removeLast() }   // trailing only: offsets stay valid
            return (s, start)
        }
        let i = tokens[token].sentence
        guard let current = sentence(i) else { return nil }
        let w = tokens[token].range
        return KaraokeLine(previous: sentence(i - 1)?.text, current: current.text,
                           word: (w.lowerBound - current.start)..<(w.upperBound - current.start), next: sentence(i + 1)?.text)
    }
}

struct KaraokeLine: Equatable {
    var previous: String?
    var current: String
    /// UTF-16 range of the spoken word inside `current`.
    var word: Range<Int>?
    var next: String?
}

/// A loaded document ready to show.
struct ReaderDocument {
    let text: String
    let tokens: [Token]
    let sentences: [Range<Int>]
    let pdf: PDFDocument?
    let pageStarts: [Int]
}

struct ReaderView: View {
    @ObservedObject var model: AppModel
    let item: LibraryItem
    let data: ViewData
    @State private var doc: ReaderDocument?
    @State private var failure: String?

    var body: some View {
        Group {
            if let doc {
                if let session = model.session, session.text == doc.text {
                    LiveReader(model: model, item: item, data: data, doc: doc, session: session)
                } else {
                    ReaderPage(model: model, item: item, data: data, doc: doc, current: data.previewToken, state: nil)
                }
            } else if let failure {
                ContentUnavailableView("Can't show this document", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.surface)
        .navigationTitle(item.title)
        .task(id: item.id) { load() }
    }

    private func load() {
        do {
            let text = try data.documentText(item)
            let tokens = TextKit.tokenize(text)
            var pdf: PDFDocument?
            var starts: [Int] = []
            if item.kind == "pdf", let p = PDFDocument(url: Paths.documents.appendingPathComponent(item.fileName)) {
                pdf = p
                starts = Importer.pdfText(p).pageStarts   // same joining as the importer, so offsets match the read text
            }
            doc = ReaderDocument(text: text, tokens: tokens, sentences: ReadingText.sentenceRanges(tokens), pdf: pdf, pageStarts: starts)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Follows the live session's word.
private struct LiveReader: View {
    let model: AppModel
    let item: LibraryItem
    let data: ViewData
    let doc: ReaderDocument
    @ObservedObject var session: ReadSession
    var body: some View {
        ReaderPage(model: model, item: item, data: data, doc: doc, current: session.currentToken, state: session.state)
    }
}

private struct ReaderPage: View {
    @ObservedObject var model: AppModel
    let item: LibraryItem
    let data: ViewData
    let doc: ReaderDocument
    let current: Int?
    /// nil when no session is reading this document.
    let state: ReadSession.State?
    @AppStorage("readerWiderSpacing") private var wider = false
    @State private var lastSaved = Date.distantPast

    private var live: Bool { state != nil }
    private var colour: NSColor { NSColor(hex: model.settings.highlightHex) ?? Theme.accentNS }
    private var savedPosition: Int { data.library.first { $0.id == item.id }?.position ?? item.position }

    private var word: NSRange? {
        guard let c = current, doc.tokens.indices.contains(c) else { return nil }
        return NSRange(location: doc.tokens[c].range.lowerBound, length: doc.tokens[c].range.count)
    }
    private var sentence: NSRange? {
        guard model.settings.tintEnabled, let c = current, doc.tokens.indices.contains(c) else { return nil }
        let s = doc.sentences[doc.tokens[c].sentence]
        // Include the closing punctuation ("Tuesday." / "running.”").
        let ns = doc.text as NSString
        var end = s.upperBound
        while end < ns.length, end - s.upperBound < 3, let u = UnicodeScalar(ns.character(at: end)), CharacterSet.punctuationCharacters.contains(u) { end += 1 }
        return NSRange(location: s.lowerBound, length: end - s.lowerBound)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let pdf = doc.pdf {
                PDFReader(document: pdf, pageStarts: doc.pageStarts, word: word, sentence: sentence, colour: colour,
                          follow: state == .playing, onClick: start(at:))
            } else {
                TextReader(text: doc.text, word: word, sentence: sentence, colour: colour, wider: wider, follow: state == .playing,
                           restore: live || savedPosition <= 0 || savedPosition >= doc.tokens.count ? nil : doc.tokens[savedPosition].range.lowerBound,
                           onClick: start(at:), onSpace: playPause)
            }
            transport.padding(.bottom, 18)
        }
        .onChange(of: current) { _, token in
            guard live, let token, Date().timeIntervalSince(lastSaved) > 2 else { return }
            model.savePosition(item, token: token)
            lastSaved = Date()
        }
        .onChange(of: state) { _, s in
            if let token = current, s == .paused || s == .finished { model.savePosition(item, token: s == .finished ? doc.tokens.count - 1 : token) }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            SymbolButton(symbol: "backward.fill", label: "Previous sentence (⌘[)") { model.skip(-1) }
                .keyboardShortcut("[", modifiers: .command).disabled(!live)
            PlayButton(playing: state == .playing, size: 42) { playPause() }
                .keyboardShortcut(.space, modifiers: [])
            SymbolButton(symbol: "forward.fill", label: "Next sentence (⌘])") { model.skip(1) }
                .keyboardShortcut("]", modifiers: .command).disabled(!live)
            Divider().frame(height: 22).padding(.horizontal, 6)
            SpeedMenu(speed: Double(model.activeSpeed)) { model.setSpeed(Float($0)) }
            VoiceMenu(voices: data.voices, english: model.settings.voiceID, french: model.settings.frenchVoiceID) { model.setVoice($0) }
            if doc.pdf == nil {
                SymbolButton(symbol: "textformat.size", label: wider ? "Normal spacing" : "Wider spacing") { wider.toggle() }
                    .foregroundStyle(wider ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
            }
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 7)
        .panelSurface(Capsule())
        .background {   // ⌘+ / ⌘− change speed by 0.1
            Group {
                Button("Faster") { nudgeSpeed(0.1) }.keyboardShortcut("=", modifiers: .command)
                Button("Slower") { nudgeSpeed(-0.1) }.keyboardShortcut("-", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    private func nudgeSpeed(_ delta: Double) { model.stepSpeed(Float(delta)) }

    private func playPause() {
        switch state {
        case .playing?, .paused?, .preparing?: model.togglePause()
        default: model.read(item, fromToken: savedPosition < doc.tokens.count - 1 ? savedPosition : 0)
        }
    }

    private func start(at offset: Int) {
        guard let token = ReadingText.token(at: offset, in: doc.tokens) else { return }
        model.read(item, fromToken: token)
    }
}

struct SpeedMenu: View {
    let speed: Double
    let set: (Double) -> Void
    var body: some View {
        Menu {
            ForEach(Theme.speedPresets, id: \.self) { p in
                Toggle(Theme.speed(p), isOn: Binding(get: { abs(speed - p) < 0.001 }, set: { _ in set(p) }))
            }
        } label: {
            Text(Theme.speed(speed)).font(.callout.weight(.semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Speed \(Theme.speed(speed))")
        .help("Speed (⌘+ / ⌘−)")
    }
}

/// Female voices by model, then the French ones; ticks on the English and the French voice. A choice applies to the
/// next read.
struct VoiceMenu: View {
    let voices: [Voice]
    let english: String
    let french: String
    /// The label; nil shows the English voice (the mini player passes the voice speaking now).
    var title: String?
    let choose: (String) -> Void

    var body: some View {
        let label = title ?? VoiceGroups.name(english, in: voices)
        let frenchVoices = VoiceGroups.byModel(voices, language: "fr").flatMap { g in g.voices.map { (model: g.model, voice: $0) } }
        Menu {
            ForEach(VoiceGroups.byModel(voices, language: "en"), id: \.model) { group in
                Section(group.model.modelName) {
                    ForEach(group.voices) { v in
                        Toggle(VoiceGroups.label(v), isOn: Binding(get: { v.id == english }, set: { _ in choose(v.id) }))
                    }
                }
            }
            if !frenchVoices.isEmpty {
                Section("French") {
                    ForEach(frenchVoices, id: \.voice.id) { f in
                        Toggle("\(f.voice.name) (\(f.model.modelName))", isOn: Binding(get: { f.voice.id == french }, set: { _ in choose(f.voice.id) }))
                    }
                }
            }
            Divider()
            Button("More voices…") { WindowRouter.shared.show(.voices) }
        } label: {
            Label(label, systemImage: "person.wave.2").font(.callout)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Voice: \(label)")
    }
}

// MARK: - Text

struct TextReader: NSViewRepresentable {
    let text: String
    let word: NSRange?
    let sentence: NSRange?
    let colour: NSColor
    let wider: Bool
    let follow: Bool
    /// UTF-16 offset to scroll to once on open (the saved reading position).
    let restore: Int?
    let onClick: (Int) -> Void
    let onSpace: () -> Void

    final class Coordinator {
        var text: String?
        var wider = false
        var word: NSRange?
        var restored = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 0)   // room above the floating transport
        let view = ReaderTextView.make()
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ReaderTextView, let lm = view.layoutManager else { return }
        let c = context.coordinator
        view.onClick = onClick
        view.onSpace = onSpace
        if c.text != text || c.wider != wider {
            view.textStorage?.setAttributedString(ReaderTextView.styled(text, wider: wider))
            c.text = text
            c.wider = wider
            c.word = nil
        }
        if c.word != word {
            if let old = c.word, NSMaxRange(old) <= view.string.utf16.count { lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old) }
            if let w = word { lm.addTemporaryAttribute(.foregroundColor, value: Theme.onAccentNS, forCharacterRange: w) }
            c.word = word
            if follow, let w = word { view.scrollToMiddleThird(w, in: scroll, animated: true) }
        }
        view.word = word
        view.sentence = sentence
        view.colour = colour
        view.needsDisplay = true
        if !c.restored, let r = restore {
            c.restored = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { view.scrollToMiddleThird(NSRange(location: r, length: 1), in: scroll, animated: false) }
        }
    }
}

/// Read-only, selectable text at a comfortable reading width; highlights are drawn behind the glyphs, so the text
/// storage never changes while reading.
final class ReaderTextView: NSTextView {
    static let font = NSFont.systemFont(ofSize: 19)
    var word: NSRange?
    var sentence: NSRange?
    var colour = Theme.accentNS
    var onClick: ((Int) -> Void)?
    var onSpace: (() -> Void)?

    static func make() -> ReaderTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()   // TextKit 1: temporary attributes and glyph geometry
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("Document text")
        return view
    }

    static func styled(_ text: String, wider: Bool) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = wider ? 1.75 : 1.5
        p.paragraphSpacing = wider ? 8 : 4
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
        if wider { attributes[.kern] = 0.9 }
        return NSAttributedString(string: text, attributes: attributes)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = NSSize(width: max(32, (newSize.width - Theme.readingWidth) / 2), height: 36)
        if textContainerInset != inset { textContainerInset = inset }
    }

    /// One rect per line, tight around the glyphs (line spacing excluded), in view coordinates.
    func glyphRects(_ range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let tc = textContainer, range.location != NSNotFound, NSMaxRange(range) <= string.utf16.count else { return [] }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        let f = Self.font
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            let g = lm.glyphIndex(for: NSPoint(x: r.minX + 1, y: r.midY), in: tc)
            let baseline = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + lm.location(forGlyphAt: g).y
            rects.append(NSRect(x: r.minX, y: baseline - f.ascender, width: r.width, height: f.ascender - f.descender)
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return rects
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let s = sentence {
            colour.withAlphaComponent(0.25).setFill()
            for r in glyphRects(s) { NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4).fill() }
        }
        if let w = word {
            colour.setFill()
            for r in glyphRects(w) { NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -1), xRadius: 6, yRadius: 6).fill() }
        }
    }

    func scrollToMiddleThird(_ range: NSRange, in scroll: NSScrollView, animated: Bool) {
        guard let r = glyphRects(range).first else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let third = visible.height / 3
        guard r.midY < visible.minY + third || r.midY > visible.maxY - third else { return }
        let maxY = max(0, frame.height - visible.height + scroll.contentInsets.bottom)
        let target = NSPoint(x: visible.minX, y: min(max(0, r.midY - visible.height / 2), maxY))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    /// A plain click (no drag, no double click) reads from that word. NSTextView tracks the mouse until it is released.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        onClick?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onSpace?() } else { super.keyDown(with: event) }
    }
}

// MARK: - PDF

struct PDFReader: NSViewRepresentable {
    let document: PDFDocument
    let pageStarts: [Int]
    let word: NSRange?
    let sentence: NSRange?
    let colour: NSColor
    let follow: Bool
    let onClick: (Int) -> Void

    final class Coordinator { var word: NSRange? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClickPDFView {
        let view = ClickPDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.setAccessibilityLabel("PDF document")
        return view
    }

    func updateNSView(_ view: ClickPDFView, context: Context) {
        view.pageStarts = pageStarts
        view.onClick = onClick
        var marks: [PDFSelection] = []
        if let s = sentence, let sel = view.selection(for: s) { sel.color = colour.withAlphaComponent(0.25); marks.append(sel) }
        let wordSelection = word.flatMap(view.selection(for:))
        if let sel = wordSelection { sel.color = colour.withAlphaComponent(0.6); marks.append(sel) }
        view.highlightedSelections = marks.isEmpty ? nil : marks
        if follow, word != context.coordinator.word, let sel = wordSelection, let page = sel.pages.first {
            let r = view.convert(sel.bounds(for: page), from: page)
            if !view.bounds.insetBy(dx: 0, dy: view.bounds.height / 4).contains(r) { view.go(to: sel) }
        }
        context.coordinator.word = word
    }
}

final class ClickPDFView: PDFView {
    var pageStarts: [Int] = []
    var onClick: ((Int) -> Void)?
    private var downAt: NSPoint?

    /// Selection for a range of the importer's joined text (may span pages).
    func selection(for range: NSRange) -> PDFSelection? {
        guard let doc = document else { return nil }
        var result: PDFSelection?
        for (i, start) in pageStarts.enumerated() {
            guard let page = doc.page(at: i) else { continue }
            let end = start + (page.string?.utf16.count ?? 0)
            let lo = max(range.location, start), hi = min(NSMaxRange(range), end)
            guard lo < hi, let sel = page.selection(for: NSRange(location: lo - start, length: hi - lo)) else { continue }
            if let result { result.add(sel) } else { result = sel }
        }
        return result
    }

    /// Importer text offset at a point in this view, or nil off the text.
    func textOffset(at point: NSPoint) -> Int? {
        guard let doc = document, let page = page(for: point, nearest: false) else { return nil }
        let i = doc.index(for: page)
        let ch = page.characterIndex(at: convert(point, to: page))
        guard ch >= 0, pageStarts.indices.contains(i) else { return nil }
        return pageStarts[i] + ch
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        super.mouseDown(with: event)
        if NSEvent.pressedMouseButtons & 1 == 0 { finishClick(event) }   // PDFView tracked the whole click itself
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishClick(event)
    }

    /// A plain click (no drag, no selection) reads from that word.
    private func finishClick(_ event: NSEvent) {
        guard let start = downAt else { return }
        downAt = nil
        let end = window?.mouseLocationOutsideOfEventStream ?? start
        guard event.clickCount == 1, hypot(end.x - start.x, end.y - start.y) < 4, currentSelection?.string?.isEmpty ?? true,
              let offset = textOffset(at: convert(start, from: nil)) else { return }
        onClick?(offset)
    }
}
