// `TalkRead --selftest-ui-snapshots` (the lead wires the argv case to `UISnapshots.run()`): renders every screen offscreen
// to PNG in light and dark, never showing a window, and checks the reader's click and highlight geometry. Owned by WP6.
import AppKit
import PDFKit
import SwiftUI
import TalkReadCore

@MainActor enum UISnapshots {
    static let output = URL(fileURLWithPath: "/private/tmp/talkread-wp6-shots", isDirectory: true)
    /// Source checkout root (fixtures and icon); this is a developer self-test, not a shipped feature.
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let sampleText = """
    The harbour town of Marlowe Quay woke slowly on a grey Tuesday. By a quarter to seven the first ferry had left, carrying \
    two hundred passengers and a van full of fresh bread. "You'll miss it if you dawdle," shouted Mrs Okafor, waving her umbrella \
    at a boy who was, in fact, already running.

    At the council office, the new harbour liaison spread out her notes. The agenda was short but dense: repair the sea wall \
    before the autumn storms, agree the summer ferry timetable, and decide what to do about the gulls.

    Nobody expected the gulls to take the longest.
    """

    static func run() -> Int32 {
        guard let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], !home.isEmpty else {
            print("Set TALKREAD_HOME to a disposable folder first (the self-test writes sample files there).")
            return 2
        }
        NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no activation, no windows on screen
        if let icon = NSImage(contentsOf: repo.appendingPathComponent("Resources/AppIcon.icns")) { NSApp.applicationIconImage = icon }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
        let pdfFixture = repo.appendingPathComponent("Tests/Fixtures/documents/sample.pdf")
        try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent("sample.pdf"))
        try? FileManager.default.copyItem(at: pdfFixture, to: Paths.documents.appendingPathComponent("sample.pdf"))
        WordMapEditor.save([.init(key: "Okafor", value: "oh-KAH-for"), .init(key: "Nguyen", value: "win")], to: Paths.pronunciations)
        WordMapEditor.save([.init(key: "talk and read", value: "Talk and Read"), .init(key: "marlow key", value: "Marlowe Quay")], to: Paths.vocabulary)

        let model = AppModel.shared
        model.settings.voiceID = "bf_emma"
        model.settings.speed = 1.5
        let data = sample()
        let empty = ViewData(voices: data.voices, library: [], recentReads: [], dictations: [], permissions: Permissions(),
                             voiceModel: .missing(megabytes: 330), dictationModel: .missing(megabytes: 570), documentText: { _ in "" })
        let tokens = TextKit.tokenize(sampleText)
        let line = ReadingText.karaoke(text: sampleText, tokens: tokens, sentences: ReadingText.sentenceRanges(tokens), token: 9)

        func router(_ pane: WindowRouter.Pane, _ path: [LibraryItem] = []) -> WindowRouter {
            let r = WindowRouter()
            r.pane = pane
            r.libraryPath = path
            return r
        }
        let main = CGSize(width: 980, height: 680)
        var pdfData = data
        pdfData.previewToken = 24
        var shots: [(String, CGSize, Bool, AnyView)] = [
            ("main-home", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.home)))),
            ("main-home-first-run", main, true, AnyView(MainWindowContent(model: model, data: empty, router: router(.home)))),
            ("main-library", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.library)))),
            ("main-library-empty", main, true, AnyView(MainWindowContent(model: model, data: empty, router: router(.library)))),
            ("main-reader-text", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.library, [data.library[1]])))),
            ("main-reader-pdf", main, true, AnyView(MainWindowContent(model: model, data: pdfData, router: router(.library, [data.library[0]])))),
            ("main-dictation", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.dictation)))),
            ("main-dictation-vocabulary", main, true, AnyView(DictationPane(model: model, data: data, showVocabulary: true).frame(width: 760, height: 620))),
            ("main-voices", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.voices)))),
            ("main-settings", main, true, AnyView(MainWindowContent(model: model, data: data, router: router(.settings)))),
        ]
        for tab in SettingsContent.Tab.allCases {
            shots.append(("settings-\(tab.rawValue)", CGSize(width: 760, height: 560), true, AnyView(SettingsContent(model: model, data: data, tab: tab))))
        }
        for step in 0..<4 {
            shots.append(("onboarding-\(step + 1)", CGSize(width: 600, height: 540), true,
                          AnyView(OnboardingContent(model: model, data: data, onFinish: {}, step: step))))
        }
        let voices = data.voices
        func player(_ line: KaraokeLine?, _ state: ReadSession.State?, _ status: String, note: String? = nil, expanded: Bool = false) -> AnyView {
            AnyView(MiniPlayerView(model: model, voices: voices, line: line, state: state, status: status, note: note,
                                   expanded: .constant(expanded), close: {}).padding(24))
        }
        shots += [
            ("mini-player", CGSize(width: 488, height: 144), false, player(line, .playing, "")),
            ("mini-player-subtitles", CGSize(width: 488, height: 244), false, player(line, .playing, "", expanded: true)),
            ("mini-player-clipboard", CGSize(width: 488, height: 144), false, player(line, .paused, "", note: "Reading clipboard")),
            ("mini-player-preparing", CGSize(width: 488, height: 144), false, player(nil, .preparing, "Preparing voice… 34 %")),
            ("mini-player-nothing-selected", CGSize(width: 488, height: 144), false, player(nil, nil, "Select some text first")),
        ]

        var failures = 0
        var written = 0
        for (name, size, titled, view) in shots {
            for dark in [false, true] {
                let url = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                if render(view, size: size, titled: titled, dark: dark, to: url, wait: name.contains("pdf") ? 3 : 0.7) { written += 1 } else { failures += 1; print("FAIL render \(url.lastPathComponent)") }
            }
        }
        print("rendered \(written) PNGs to \(output.path)")

        failures += checks(tokens: tokens, line: line)

        print("\nMenu bar menu (stub model state):")
        for row in MenuBarMenu(model: model, openMain: {}, openSettings: {}, openOnboarding: {}).dump() { print("  " + row) }
        print(failures == 0 ? "PASS ui self-test" : "FAIL ui self-test: \(failures) failing")
        return failures == 0 ? 0 : 1
    }

    /// Offscreen window (never ordered in) → bitmap. Titled windows include the title bar and toolbar.
    static func render(_ view: AnyView, size: CGSize, titled: Bool, dark: Bool, to url: URL, wait: Double = 0.7) -> Bool {
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if !titled {
            window.isOpaque = false
            window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.86, alpha: 1)   // stand-in desktop
        }
        window.contentView = NSHostingView(rootView: view.environment(\.offscreenRender, true))
        window.setContentSize(size)
        RunLoop.current.run(until: Date().addingTimeInterval(wait))   // let SwiftUI lay out and run .task loads
        guard let content = window.contentView else { return false }
        let target = titled ? content.superview ?? content : content
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return false }
        target.cacheDisplay(in: target.bounds, to: rep)
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: Logic checks (no windows, no input events)

    static func checks(tokens: [Token], line: KaraokeLine?) -> Int {
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
            if !ok { failures += 1 }
        }

        // Text reader: the centre of each word's drawn box maps back to that word (click → read from it), and the box is
        // glyph-tight (not the 1.5× line height).
        let view = ReaderTextView.make()
        view.setFrameSize(NSSize(width: 900, height: 400))
        view.textStorage?.setAttributedString(ReaderTextView.styled(sampleText, wider: false))
        if let lm = view.layoutManager, let tc = view.textContainer { lm.ensureLayout(for: tc) }
        let probes = [0, 9, tokens.count / 2, tokens.count - 1]
        var hits: [String] = []
        var tight = true
        for t in probes {
            let r = NSRange(location: tokens[t].range.lowerBound, length: tokens[t].range.count)
            guard let box = view.glyphRects(r).first else { hits.append("\(t):no box"); continue }
            let found = ReadingText.token(at: view.characterIndexForInsertion(at: NSPoint(x: box.midX, y: box.midY)), in: tokens)
            hits.append("\(t)→\(found.map(String.init) ?? "nil")")
            if found != t { tight = false }
            if box.height > ReaderTextView.font.pointSize * 1.4 { tight = false }
        }
        check(tight, "text click maps to word", hits.joined(separator: " ") + " (box height \(view.glyphRects(NSRange(location: tokens[9].range.lowerBound, length: 1)).first.map { String(format: "%.1f", $0.height) } ?? "?") pt)")
        let between = ReadingText.token(at: tokens[3].range.upperBound + 1, in: tokens)
        check(between == 4, "click between words → next word", "offset after token 3 → \(between.map(String.init) ?? "nil")")

        // PDF reader: a word's selection on page 2 maps back through the page offsets to the same word.
        if let pdf = PDFDocument(url: repo.appendingPathComponent("Tests/Fixtures/documents/sample.pdf")) {
            let (text, starts) = Importer.pdfText(pdf)
            let pdfTokens = TextKit.tokenize(text)
            let pdfView = ClickPDFView()
            pdfView.document = pdf
            pdfView.pageStarts = starts
            var detail: [String] = []
            var ok = starts.count == 2
            for t in [5, pdfTokens.firstIndex { $0.range.lowerBound >= starts[1] }.map { $0 + 3 } ?? 0] {
                let r = NSRange(location: pdfTokens[t].range.lowerBound, length: pdfTokens[t].range.count)
                guard let sel = pdfView.selection(for: r), let page = sel.pages.first else { ok = false; detail.append("\(t):no selection"); continue }
                let b = sel.bounds(for: page)
                let offset = starts[pdf.index(for: page)] + page.characterIndex(at: NSPoint(x: b.midX, y: b.midY))
                let found = ReadingText.token(at: offset, in: pdfTokens)
                detail.append("\(t) \"\(pdfTokens[t].text)\" p\(pdf.index(for: page) + 1)→\(found.map(String.init) ?? "nil")")
                if found != t || sel.string != pdfTokens[t].text { ok = false }
            }
            check(ok, "PDF click maps to word", detail.joined(separator: ", "))
        } else {
            check(false, "PDF click maps to word", "fixture missing")
        }

        // Mini player karaoke: the highlighted range is the spoken word.
        if let line, let w = line.word {
            let shown = (line.current as NSString).substring(with: NSRange(location: w.lowerBound, length: w.count))
            check(shown == tokens[9].text && line.previous == nil && line.next != nil, "karaoke word", "\"\(shown)\" in \"\(line.current.prefix(48))…\"")
        } else { check(false, "karaoke word", "no line") }
        check(ReadingText.sentenceRanges(tokens).count == (tokens.last?.sentence ?? -1) + 1, "sentence ranges", "\(ReadingText.sentenceRanges(tokens).count) sentences")

        // Shortcut recorder and menu key equivalents.
        let r = ShortcutRecorder.make(keyCode: 15, flags: [.control, .option], characters: "r")
        check(r?.display == "⌃⌥R" && r?.modifiers == (1 << 18 | 1 << 19), "record ⌃⌥R", "\(r?.display ?? "nil") modifiers=\(r?.modifiers ?? 0)")
        let s = ShortcutRecorder.make(keyCode: 49, flags: [.command, .shift], characters: " ")
        check(s?.display == "⇧⌘Space", "record ⇧⌘Space", s?.display ?? "nil")
        check(ShortcutRecorder.make(keyCode: 15, flags: [.shift], characters: "r") == nil && ShortcutRecorder.make(keyCode: 15, flags: [], characters: "r") == nil,
              "needs ⌃ ⌥ or ⌘", "⇧R and R refused")
        // Sol #15: the hotkeys stand down while a recorder listens; only one listens; a stale end changes nothing.
        let focus = RecorderFocus.shared, a = UUID(), b = UUID()
        var paused: [Bool] = []
        focus.begin(a); paused.append(AppModel.shared.hotkeysPaused)
        focus.begin(b); paused.append(AppModel.shared.hotkeysPaused && focus.active == b)
        focus.end(a); paused.append(AppModel.shared.hotkeysPaused && focus.active == b)
        focus.end(b); paused.append(AppModel.shared.hotkeysPaused || focus.active != nil)
        check(paused == [true, true, true, false], "recorder pauses hotkeys", "begin a, begin b, end a, end b → \(paused)")
        let key = MenuBarMenu.keyEquivalent(TalkReadCore.Settings().readShortcut)
        check(key?.0 == "r" && key?.1 == [.control, .option], "menu key equivalent", "\(key.map { "\($0.0) \($0.1.rawValue)" } ?? "nil")")
        let cycle = [1.0, 1.23, 2.5].map(SpeedControl.SpeedButton.next(after:))
        check(cycle == [1.5, 1.5, 1.0], "speed button cycles", cycle.map { Theme.speed($0) }.joined(separator: " "))
        return failures
    }

    // MARK: Sample data (invented)

    static func sample() -> ViewData {
        let now = Date()
        let voices = [
            Voice(id: "bf_emma", name: "Emma", accent: "British", gender: "Female", engine: .neural, installed: true),
            Voice(id: "bf_isabella", name: "Isabella", accent: "British", gender: "Female", engine: .neural, installed: true),
            Voice(id: "bm_george", name: "George", accent: "British", gender: "Male", engine: .neural, installed: true),
            Voice(id: "bm_lewis", name: "Lewis", accent: "British", gender: "Male", engine: .neural, installed: true),
            Voice(id: "af_heart", name: "Heart", accent: "American", gender: "Female", engine: .neural, installed: true),
            Voice(id: "af_bella", name: "Bella", accent: "American", gender: "Female", engine: .neural, installed: true),
            Voice(id: "am_michael", name: "Michael", accent: "American", gender: "Male", engine: .neural, installed: true),
            Voice(id: "com.apple.voice.premium.en-GB.Serena", name: "Serena (Premium)", accent: "British", gender: "Female", engine: .system, installed: true),
            Voice(id: "com.apple.voice.enhanced.en-US.Ava", name: "Ava (Enhanced)", accent: "American", gender: "Female", engine: .system, installed: true),
        ]
        func item(_ title: String, _ kind: String, _ file: String, _ days: Double, _ position: Int) -> LibraryItem {
            LibraryItem(id: UUID(), title: title, kind: kind, fileName: file, added: now.addingTimeInterval(-days * 86_400), position: position)
        }
        let library = [
            item("Marlowe Quay Lighthouse", "pdf", "sample.pdf", 1, 40),
            item("The harbour town of Marlowe Quay", "pasted", "pasted.txt", 0.1, 9),
            item("Ferry news & times", "web", "web.txt", 3, 0),
            item("Harbour ledger", "docx", "ledger.docx", 6, 999),
            item("The EPUB Fixture", "epub", "book.epub", 12, 30),
            item("Tide tables", "markdown", "tides.md", 20, 0),
        ]
        let reads = [
            ReadEntry(id: UUID(), date: now.addingTimeInterval(-300), app: "Safari", text: "The council agreed the summer ferry timetable after a long debate about the gulls."),
            ReadEntry(id: UUID(), date: now.addingTimeInterval(-7_200), app: "Mail", text: "Hi Junior, the draft is attached. Could you read it before Thursday?"),
            ReadEntry(id: UUID(), date: now.addingTimeInterval(-90_000), app: "Preview", text: "Section 4: the duty of care owed by a harbour authority to visitors."),
        ]
        let dictations = [
            DictationEntry(id: UUID(), date: now.addingTimeInterval(-600), text: "Thanks for this. I'll send the edits over by Friday afternoon.", app: "Mail"),
            DictationEntry(id: UUID(), date: now.addingTimeInterval(-5_400), text: "Remember to book the ferry for the 14th, the early one at 6:10.", app: "Notes"),
            DictationEntry(id: UUID(), date: now.addingTimeInterval(-80_000), text: "Can we move the call to 3 pm?", app: "Messages"),
        ]
        let pdfURL = Paths.documents.appendingPathComponent("sample.pdf")
        return ViewData(voices: voices, library: library, recentReads: reads, dictations: dictations,
                        permissions: Permissions(accessibility: true, microphone: false, screenRecording: false),
                        voiceModel: .downloading(progress: 0.34), dictationModel: .missing(megabytes: 570),
                        documentText: { $0.kind == "pdf" ? ((try? Importer.load(pdfURL))?.text ?? "") : sampleText },
                        previewToken: 9)
    }
}
