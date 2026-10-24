// `TalkRead --selftest-asr <dir> [--insert | --paragraphs]`: hotkey mapping, the focus rule, Copy and the result pill's
// timing, the pill's window (outside every display), the ownership rules (fake recorder and recogniser),
// WER and latency of the real Transcriber over the fixtures (file path and live streaming path), paragraph breaks on a
// Kokoro-spoken four-paragraph script, and, with --insert, pasting into a test panel on the Prompter XL. Never uses the microphone; events go only to our own pid.
import AppKit
import AVFoundation
import FluidAudio
import SwiftUI
import TalkReadCore
import WebKit

@MainActor enum DictationSelfTest {
    static func run(dir: String) async -> Int32 {
        // History and settings go to a scratch home unless the caller chose one (never the real data root).
        if ProcessInfo.processInfo.environment["TALKREAD_HOME"] == nil {
            setenv("TALKREAD_HOME", "/private/tmp/talkread-selftest-home", 1)
        }
        if CommandLine.arguments.contains("--bench") { return await DictationBench.run(dir: URL(fileURLWithPath: dir)) }
        if CommandLine.arguments.contains("--paragraphs") {       // just the paragraph check
            let transcriber = Transcriber()
            guard (try? await transcriber.load(progress: nil)) != nil else { return 1 }
            let clips = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["wav", "m4a"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return await checkParagraphs(transcriber, clips: clips) ? 0 : 1
        }
        var ok = checkHotkeys()
        ok = checkTextRules() && ok
        ok = checkFocusRule() && ok
        if Paths.dataRoot.path.hasPrefix("/private/tmp") {
            ok = await checkResult() && ok
            ok = await checkPillWindow() && ok
            ok = await checkMicFallback() && ok
            ok = await checkOwnership(fixture: URL(fileURLWithPath: dir)) && ok
            ok = await checkDrain(fixture: URL(fileURLWithPath: dir)) && ok
        } else {
            print("ownership: NOT RUN (data root \(Paths.dataRoot.path) is not a scratch folder)")
            ok = false
        }
        ok = await checkASR(dir: URL(fileURLWithPath: dir)) && ok
        if CommandLine.arguments.contains("--insert") { ok = await checkInsertion() && ok }
        print(ok ? "selftest-asr: PASS" : "selftest-asr: FAIL")
        return ok ? 0 : 1
    }

    // MARK: Hotkeys

    private static func checkHotkeys() -> Bool {
        let s = Settings()
        var fn = Settings()
        fn.dictationHoldKey = .fn
        var cmd = Settings()
        cmd.dictationHoldKey = .rightCommand
        var off = Settings()
        off.readShortcut = .off   // turned off in Settings
        let ropt: UInt64 = Hotkeys.option | Hotkeys.rightOptionDeviceBit
        let rcmd: UInt64 = Hotkeys.command | Hotkeys.rightCommandDeviceBit
        let ctrl = Hotkeys.control, opt = Hotkeys.option, command = Hotkeys.command
        let cases: [(String, KeyEvent?, KeyEvent?)] = [
            ("right option down", Hotkeys.keyEvent(.flagsChanged, keyCode: 61, flags: ropt, settings: s), .holdKeyDown),
            ("right option up", Hotkeys.keyEvent(.flagsChanged, keyCode: 61, flags: 0, settings: s), .holdKeyUp),
            ("right option with cmd held", Hotkeys.keyEvent(.flagsChanged, keyCode: 61, flags: ropt | command, settings: s),
             .otherKeyDown(keyCode: 61, modifiers: ropt | command)),
            ("left option is not the hold key", Hotkeys.keyEvent(.flagsChanged, keyCode: 58, flags: opt | 0x20, settings: s),
             .otherKeyDown(keyCode: 58, modifiers: opt | 0x20)),
            ("shift released", Hotkeys.keyEvent(.flagsChanged, keyCode: 56, flags: 0, settings: s), nil),
            // S1 defaults (Junior's Speechify set).
            ("ctrl+A", Hotkeys.keyEvent(.keyDown, keyCode: 0, flags: ctrl, settings: s), .chord(.read)),
            ("ctrl+opt+Q", Hotkeys.keyEvent(.keyDown, keyCode: 12, flags: ctrl | opt, settings: s), .chord(.pause)),
            ("ctrl+opt+cmd+X", Hotkeys.keyEvent(.keyDown, keyCode: 7, flags: ctrl | opt | command, settings: s), .chord(.screenshot)),
            ("ctrl+` (device bits ignored)", Hotkeys.keyEvent(.keyDown, keyCode: 50, flags: ctrl | 0x100, settings: s), .chord(.toggleRecording)),
            ("ctrl+cmd+V", Hotkeys.keyEvent(.keyDown, keyCode: 9, flags: ctrl | command, settings: s), .chord(.pasteLast)),
            ("opt+D", Hotkeys.keyEvent(.keyDown, keyCode: 2, flags: opt, settings: s), .chord(.increaseSpeed)),
            ("opt+S", Hotkeys.keyEvent(.keyDown, keyCode: 1, flags: opt, settings: s), .chord(.decreaseSpeed)),
            ("opt+W", Hotkeys.keyEvent(.keyDown, keyCode: 13, flags: opt, settings: s), .chord(.skipBackward)),
            ("opt+E", Hotkeys.keyEvent(.keyDown, keyCode: 14, flags: opt, settings: s), .chord(.skipForward)),
            ("ctrl+shift+A is not ctrl+A", Hotkeys.keyEvent(.keyDown, keyCode: 0, flags: ctrl | Hotkeys.shift, settings: s),
             .otherKeyDown(keyCode: 0, modifiers: ctrl | Hotkeys.shift)),
            ("old ctrl+opt+R is just a key", Hotkeys.keyEvent(.keyDown, keyCode: 15, flags: ctrl | opt, settings: s),
             .otherKeyDown(keyCode: 15, modifiers: ctrl | opt)),
            ("opt+V is just a key", Hotkeys.keyEvent(.keyDown, keyCode: 9, flags: opt, settings: s),
             .otherKeyDown(keyCode: 9, modifiers: opt)),
            ("fn down (fn setting)", Hotkeys.keyEvent(.flagsChanged, keyCode: 63, flags: Hotkeys.secondaryFn, settings: fn), .holdKeyDown),
            ("right option ignored (fn setting)", Hotkeys.keyEvent(.flagsChanged, keyCode: 61, flags: ropt, settings: fn),
             .otherKeyDown(keyCode: 61, modifiers: ropt)),
            ("right command down (right command setting)", Hotkeys.keyEvent(.flagsChanged, keyCode: 54, flags: rcmd, settings: cmd), .holdKeyDown),
            ("right command up (right command setting)", Hotkeys.keyEvent(.flagsChanged, keyCode: 54, flags: 0, settings: cmd), .holdKeyUp),
            ("left command is not the hold key", Hotkeys.keyEvent(.flagsChanged, keyCode: 55, flags: command | Hotkeys.leftCommandDeviceBit, settings: cmd),
             .otherKeyDown(keyCode: 55, modifiers: command | Hotkeys.leftCommandDeviceBit)),
            ("right command with ctrl held", Hotkeys.keyEvent(.flagsChanged, keyCode: 54, flags: rcmd | ctrl, settings: cmd),
             .otherKeyDown(keyCode: 54, modifiers: rcmd | ctrl)),
            ("a turned-off shortcut never matches plain A", Hotkeys.keyEvent(.keyDown, keyCode: 0, flags: 0, settings: off),
             .otherKeyDown(keyCode: 0, modifiers: 0)),
            ("a turned-off ctrl+A is just a key", Hotkeys.keyEvent(.keyDown, keyCode: 0, flags: ctrl, settings: off),
             .otherKeyDown(keyCode: 0, modifiers: ctrl)),
        ]
        var ok = true
        for (name, got, want) in cases where got != want {
            print("hotkeys: FAIL \(name): got \(String(describing: got)), want \(String(describing: want))")
            ok = false
        }
        // The tap itself: created as an active (event-swallowing) tap, then removed. Paused while it exists, so it
        // passes every key through and nothing of Junior's typing is swallowed; nothing is injected.
        let hotkeys = Hotkeys(settings: s)
        hotkeys.paused = true
        let running = hotkeys.start()
        let active = Hotkeys.ownTapIsActive()
        hotkeys.stop()
        print("hotkeys: \(cases.count) mappings \(ok ? "ok" : "FAILED"); event tap \(running ? "created" : "NOT created (Accessibility?)"), "
              + (active ? "active (swallows matched shortcuts)" : "NOT an active tap"))
        return ok && running && active
    }

    // MARK: Terminal text and British spelling (V-F)

    private static func checkTextRules() -> Bool {
        let flat = Inserter.oneLine("Hi Jon,\nThanks.\n\n1. Trim the intro.\n2. Send it")
        let british = BritishSpelling.apply("The neighbor's color, center and organizer; email kestrelco.com or Kestrelco. Realize it.")
        let ok = flat == "Hi Jon, Thanks. 1. Trim the intro. 2. Send it" && !flat.contains("\n")
            && british == "The neighbour's colour, centre and organiser; email kestrelco.com or Kestrelco. Realise it."
            && Inserter.terminalApps.isSuperset(of: ["com.apple.Terminal", "com.googlecode.iterm2"])
        // Single-line fields (F-A) get no paragraph breaks; a text area keeps them.
        let own = ownFieldRules()
        let single = Inserter.isSingleLine(role: "AXTextField", subrole: nil) && Inserter.isSingleLine(role: "AXTextField", subrole: "AXSearchField")
            && Inserter.isSingleLine(role: "AXComboBox", subrole: nil, editable: true) && !Inserter.isSingleLine(role: "AXComboBox", subrole: nil)
            && !Inserter.isSingleLine(role: "AXTextArea", subrole: nil) && !Inserter.isSingleLine(role: nil, subrole: nil) && own
        print("text: terminal paste one line \"\(flat)\"; British \"\(british)\"; single-line field rule \(single) \(ok && single ? "ok" : "FAIL")")
        return ok && single
    }

    /// Our own controls (a window that is never shown): an NSTextField's and an NSComboBox's field editor is one-line, a text
    /// view is not, and a secure field is still secure.
    private static func ownFieldRules() -> Bool {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 150, width: 200, height: 24)), combo = NSComboBox(frame: NSRect(x: 0, y: 120, width: 200, height: 24))
        let secure = NSSecureTextField(frame: NSRect(x: 0, y: 90, width: 200, height: 24)), view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let readOnly = NSTextView(frame: NSRect(x: 210, y: 0, width: 80, height: 80))
        readOnly.isEditable = false
        for v in [field, combo, secure, view, readOnly] as [NSView] { window.contentView?.addSubview(v) }
        func state(_ responder: NSResponder) -> Inserter.Focus? {
            guard window.makeFirstResponder(responder), let editor = window.firstResponder as? NSTextView else { return nil }
            // The production route: no PID, our own process in front, the focus in `window`.
            return Inserter.focusedField(pid: nil, frontmost: { getpid() }, ownEditor: { editor })
        }
        let results = [state(field)?.singleLine, state(combo)?.singleLine, state(view)?.singleLine, state(secure)?.secure]
        let ok = results == [true, true, false, true]
        print("text: own fields (NSTextField, NSComboBox, NSTextView, secure) \(results.map { $0.map(String.init) ?? "none" }) \(ok ? "ok" : "FAIL")")
        // P-B: which of our own focuses take a paste; none at all (a web view, a button) is unknown.
        let takes = [state(field)?.takesText, state(combo)?.takesText, state(view)?.takesText, state(readOnly)?.takesText,
                     Inserter.focusedField(pid: nil, frontmost: { getpid() }, ownEditor: { nil }).takesText]
        let takesOK = takes == [true, true, true, false, nil]
        print("text: own fields take text (field, combo, text view, read-only view, none) \(takes.map { $0.map(String.init) ?? "unknown" }) \(takesOK ? "ok" : "FAIL")")
        return ok && takesOK
    }

    // MARK: The focus rule, Copy and the result pill (P-B)

    /// Whether the end of a dictation has somewhere to paste, from the focused element's AX role as apps report it.
    /// Unknown (nil) pastes as before; only a definite false skips the paste.
    private static func checkFocusRule() -> Bool {
        let t = Inserter.takesText(role:subrole:editable:caret:terminal:)
        let cases: [(String, Bool?, Bool?)] = [
            ("text field", t("AXTextField", nil, true, true, false), true),
            ("text area that AX cannot set (Terminal's)", t("AXTextArea", nil, false, true, false), true),
            ("search field", t("AXTextField", "AXSearchField", true, true, false), true),
            ("editable combo box", t("AXComboBox", nil, true, true, false), true),
            ("custom view with a caret", t("AXLayoutArea", nil, true, true, false), true),
            ("terminal without a text role", t("AXGroup", nil, false, false, true), true),
            ("pop-up combo box", t("AXComboBox", nil, false, false, false), false),
            // An editable web document or iframe reports no caret range and no settable value (Sol verification 15 #1).
            ("web area, editable or not", t("AXWebArea", nil, false, false, false), nil),
            ("web area with a selection", t("AXWebArea", nil, false, true, false), nil),
            ("file list", t("AXList", nil, false, false, false), false),
            ("outline", t("AXOutline", nil, false, false, false), false),
            ("button", t("AXButton", nil, false, false, false), false),
            ("static text", t("AXStaticText", nil, false, false, false), false),
            ("image", t("AXImage", nil, false, false, false), false),
            ("generic group (an Electron app asleep)", t("AXGroup", nil, false, false, false), nil),
            ("window", t("AXWindow", nil, false, false, false), nil),
            ("scroll area", t("AXScrollArea", nil, false, false, false), nil),
            ("no role", t(nil, nil, false, false, false), nil),
        ]
        let failed = cases.filter { $0.1 != $0.2 }.map(\.0)
        let tips = DictationPillStatus.pasteTip(Settings().pasteLastShortcut) == "Didn't land? Press ⌃⌘V to paste it"
            && DictationPillStatus.pasteTip(.off) == nil
        print("focus: \(cases.count) focus cases \(failed.isEmpty ? "ok" : "FAIL \(failed)"); paste-last tip from the shortcut, hidden when off \(tips ? "ok" : "FAIL")")
        return failed.isEmpty && tips
    }

    /// With a private pasteboard, a fake recorder and recogniser, and a fake insert that answers like the Inserter: the
    /// end of a dictation with no field pastes nothing and leaves the clipboard alone, keeps the text in the history and
    /// offers Copy, which puts it on the (private) clipboard; paste last still pastes; a password field offers nothing;
    /// the result's hide timing and hover; the ✕ closes it.
    private static func checkResult() async -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.juniornkanabassi.talkread.selftest.copy.\(getpid())"))
        let savedGate = Inserter.gate, savedFocus = Inserter.focus
        Inserter.gate = PasteboardGate(pasteboard: pb)
        defer { Inserter.gate = savedGate; Inserter.focus = savedFocus; pb.releaseGlobally() }
        let mark = "talkread-copy-sentinel"
        func sentinel() -> Int { pb.clearContents(); pb.setString(mark, forType: .string); return pb.changeCount }
        func untouched(_ count: Int) -> Bool { pb.changeCount == count && pb.string(forType: .string) == mark }

        // The real Inserter, its focus answered by the test: nothing takes text, so nothing is written and no ⌘V goes out
        // (the paste comes only after the write). Checked before Accessibility, so it runs without it too.
        Inserter.focus = { _ in (secure: false, previous: nil, terminal: false, singleLine: false, takesText: false) }
        var kept = sentinel()
        let refused = await Inserter.insert("hello there", targetPID: getpid(), requireField: true)
        expect("Inserter: no field refused", refused == .failed(Inserter.noField) || (!CGPreflightPostEventAccess() && refused != .inserted))
        expect("Inserter: no field leaves the clipboard untouched", untouched(kept))

        var calls: [(text: String, requireField: Bool)] = []
        var answer = InsertResult.failed(Inserter.noField)
        let c = DictationController(audio: FakeAudio(), asr: FakeASR()) { text, _, requireField, _ in
            calls.append((text, requireField))
            return requireField ? answer : .inserted
        }
        c.quiet = true
        let defaults = (c.holdSeconds.done, c.holdSeconds.failed)
        expect("result stays 5 s, a failure 8 s", defaults == (5, 8))
        c.holdSeconds = (done: 0.4, failed: 0.8, recheck: 0.05)
        var hovering = false
        c.pointerOverPill = { hovering }
        func dictate() async {
            try? c.start(caller: DictationController.user)
            await settle(100)
            try? c.stop(insert: true, caller: DictationController.user)
            _ = await c.result()
        }

        kept = sentinel()
        await dictate()
        let said = calls.last?.text ?? ""
        expect("the end of a dictation asks for a field", calls.last?.requireField == true)
        expect("no field: the pill says so", c.state == .failed(Inserter.noField))
        expect("no field: history kept", !said.isEmpty && c.history.first?.text == said)
        expect("no field: Copy offered", c.copyable == said)
        expect("no field: clipboard untouched until Copy", untouched(kept))
        await c.copyResult()?.value
        expect("Copy puts the dictation on the clipboard", pb.string(forType: .string) == said && c.copied)
        await settle(500)
        expect("a failure outlasts a result's 0.4 s", c.state == .failed(Inserter.noField))
        hovering = true
        await settle(500)
        expect("hover holds the failure past its 0.8 s", c.state == .failed(Inserter.noField) && c.copyable == said)
        hovering = false
        await settle(250)
        expect("pointer gone: hidden, nothing left to copy", c.state == .idle && c.copyable == nil)

        // Paste last is deliberate: it pastes whatever the focus (the user put the caret there).
        let before = calls.count
        c.pasteLast()
        await settle(100)
        expect("paste last pastes without a field check", calls.count == before + 1 && calls.last?.requireField == false && calls.last?.text == said)

        answer = .inserted
        await dictate()
        let typed = calls.last?.text ?? ""
        expect("typed: done with Copy", c.state == .done(typed) && c.copyable == typed)
        await settle(250)
        expect("typed: still shown at 0.25 s", c.state == .done(typed))
        await settle(350)
        expect("typed: hidden after 0.4 s", c.state == .idle && c.copyable == nil)

        await dictate()
        c.dismiss()
        expect("✕ closes the result", c.state == .idle && c.copyable == nil)

        answer = .failed(Inserter.noField)
        await dictate()
        // Copy pressed while a capture waits for an app's copy: it queues behind it, is not taken for that copy and
        // restored away, and stays (Sol verification 15 #2).
        let gate = Inserter.gate
        _ = sentinel()
        let capture = Task { await gate.transaction { if let from = gate.prepareToChange() { _ = await gate.waitForChange(from: from, timeout: 0.3) } } }
        await settle(50)
        let copying = c.copyResult()
        await settle(50)
        expect("not \"Copied\" while it waits behind the capture", !c.copied)
        await capture.value
        await copying?.value
        expect("Copy during a capture survives its restore", pb.string(forType: .string) == c.copyable && c.copyable != nil)
        try? c.start(caller: DictationController.user)
        expect("a new dictation drops the old Copy", c.copyable == nil)
        try? c.cancel(caller: DictationController.user)

        answer = .refusedSecure
        let entries = c.history.count
        await dictate()
        expect("password field: nothing kept, nothing to copy", c.history.count == entries && c.copyable == nil)
        let count = pb.changeCount
        await c.copyResult()?.value
        expect("password field: Copy does nothing", pb.changeCount == count)

        // A file transcription started while a result shows: the result waits for it, then goes (Sol verification 15 #3).
        let f = DictationController(audio: FakeAudio(), asr: FakeASR(), insert: { _, _, _, _ in .failed(Inserter.noField) },
                                    decode: { _ in Thread.sleep(forTimeInterval: 0.5); return [Float](repeating: 0, count: 1600) })
        f.quiet = true
        f.holdSeconds = (done: 0.2, failed: 0.2, recheck: 0.05)
        f.pointerOverPill = { false }
        try? f.start(caller: DictationController.user)
        await settle(100)
        try? f.stop(insert: true, caller: DictationController.user)
        _ = await f.result()
        let file = Task { try? await f.transcribe(file: URL(fileURLWithPath: "/dev/null"), caller: "selftest") }
        await settle(350)
        expect("a file transcription holds the result", f.state == .failed(Inserter.noField))
        _ = await file.value
        await settle(200)
        expect("the result goes once the file is done", f.state == .idle)
        print("result: no field typed nothing, kept in history, clipboard untouched until Copy; Copy during a capture; paste last; "
              + "5 s / 8 s and hover; ✕; password field; held through a file transcription \(failures.isEmpty ? "ok" : "FAIL \(failures)")")
        return failures.isEmpty
    }

    /// The 0.6.0 pill that never reached the screen (P-B): the panel was made once and ordered out and in again, and
    /// macOS 27.2 kept it off the Space it came back to (Junior's full-screen Spaces: ordered in, on no Space, never on
    /// screen). Now each appearance is a new panel. Checked on the real pill, placed outside every display so nothing
    /// shows on Junior's screens: on screen at the status-bar layer, opaque, 340 x 72 where it was put, kept while it
    /// shows, gone when hidden, a new window the next time; and the content it lays out fits it in every state.
    private static func checkPillWindow() async -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func onScreen(_ number: Int?) -> [String: Any]? {
            guard let number, number > 0 else { return nil }
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.first { ($0[kCGWindowNumber as String] as? Int) == number }
        }
        let away = NSPoint(x: -30000, y: -30000)
        let c = DictationController(audio: FakeAudio(), asr: FakeASR()) { _, _, _, _ in .failed(Inserter.noField) }
        c.quiet = true
        c.holdSeconds = (done: 30, failed: 30, recheck: 1)   // this check hides the pill itself
        let pill = DictationPill(dictation: c)

        pill.show(at: away)
        await settle(150)
        let first = pill.panel?.windowNumber
        let info = onScreen(first)
        let bounds = info?[kCGWindowBounds as String] as? [String: Double] ?? [:]
        expect("shown: on screen", info != nil)
        expect("shown: status-bar layer", info?[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)))
        expect("shown: opaque", info?[kCGWindowAlpha as String] as? Double == 1)
        expect("shown: 340 x 72 where it was put", bounds["Width"] == 340 && bounds["Height"] == 72 && bounds["X"] == away.x)
        expect("never key or main", pill.panel.map { !$0.canBecomeKey && !$0.canBecomeMain } == true)
        pill.show()                                                 // showing already: stays put, same window
        expect("shown again while showing: same window, same place", pill.panel?.windowNumber == first && pill.panel?.frame.origin == away)
        pill.hide()
        for _ in 0..<20 where onScreen(first) != nil { await settle(50) }   // the window server's fade-out
        expect("hidden: off screen, no panel", onScreen(first) == nil && pill.panel == nil)
        pill.show(at: away)
        await settle(150)
        let second = pill.panel?.windowNumber
        expect("shown after hiding: a new window, on screen", second != nil && second != first && onScreen(second) != nil)

        // The content in each state: a finite height that fits the 340 pt pill (a NaN, zero or runaway height would hide it).
        func content() -> CGSize { NSHostingView(rootView: DictationPillView(dictation: c)).fittingSize }
        var heights: [String: CGFloat] = [:]
        try? c.start(caller: DictationController.user)
        await settle(100)
        heights["recording"] = content().height
        try? c.stop(insert: true, caller: DictationController.user)
        heights["transcribing"] = content().height
        _ = await c.result()
        heights["failed with Copy"] = content().height
        let width = content().width
        let fits = heights.values.allSatisfy { $0.isFinite && $0 >= 72 && $0 <= 80 }
        expect("content fits in every state \(heights)", fits && width == DictationPill.width)
        expect("still on screen through the states", onScreen(second) != nil)
        c.dismiss()
        pill.hide()
        print("pill window: on screen at layer 25, opaque, 340 x 72, a new window each time it shows, content "
              + heights.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value))" }.joined(separator: ", ") + " pt "
              + (failures.isEmpty ? "ok" : "FAIL \(failures)"))
        return failures.isEmpty
    }

    // MARK: Ownership (PLAN decision 19) with a fake recorder and recogniser

    /// One fake input device, like the Recorder: a new start stops the old one, `stop()` during a start makes it throw
    /// `.stopped`, and `delay` is the time until the first buffer.
    private final class FakeAudio: DictationAudio {
        var onBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var log: ((String) -> Void)?                              // "mic" when an input starts
        var delay = Duration.zero
        var fallbackNotice: String?                               // what a Recorder whose device would not open reports
        private(set) var starts = 0
        private(set) var running = false
        private var session = 0
        private var waiting: CheckedContinuation<Void, Error>?

        func start() async throws {
            _ = stop()
            starts += 1
            session += 1
            running = true
            log?("mic")
            if delay > .zero {
                let id = session, delay = delay
                try await withCheckedThrowingContinuation { c in
                    waiting = c
                    Task { try? await Task.sleep(for: delay); if self.session == id { self.finishWait(.success(())) } }
                }
            }
            onBuffer?(Transcriber.buffer(ArraySlice(repeating: 0, count: 1600)))
        }

        func stop() -> [Float] {
            running = false
            session += 1
            finishWait(.failure(RecorderError.stopped))
            return []
        }

        private func finishWait(_ result: Result<Void, Error>) {
            let w = waiting
            waiting = nil
            w?.resume(with: result)
        }
    }

    /// Shaped like the Transcriber: the production `RecogniserQueue`, recognition that cancellation cannot interrupt
    /// (`work` per buffer, like `processBufferedAudio`), and a cold load (`loadTime`) that runs to the end while a
    /// cancelled caller stops waiting at once.
    private final class FakeASR: DictationASR {
        private let queue = RecogniserQueue()
        var isLoaded = true
        private(set) var isLoading = false { didSet { onLoadingChange?() } }
        var onLoadingChange: (() -> Void)?
        var loadTime = Duration.zero
        var work = Duration.milliseconds(50)
        var log: ((String) -> Void)?                              // "enter" and "exit" of recognition
        private(set) var entered = 0
        private var count = 0

        func load(progress: ((Double) -> Void)?) async throws {
            if isLoaded { return }
            if !isLoading {
                isLoading = true
                let loadTime = loadTime
                Task { await Self.uninterruptible(loadTime); isLoaded = true; isLoading = false }
            }
            while isLoading { try await Task.sleep(for: .milliseconds(5)) }
        }

        @discardableResult func unload() -> Bool {
            guard !queue.inUse, !isLoading else { return false }
            isLoaded = false
            return true
        }

        func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> Transcript {
            try await queue.exclusive {
                try await load(progress: nil)
                entered += 1
                log?("enter")
                defer { log?("exit") }
                for await _ in audio {
                    try Task.checkCancellation()
                    await Self.uninterruptible(work)
                }
                try Task.checkCancellation()
                count += 1
                return Transcript(text: "utterance \(count)")
            }
        }

        static func uninterruptible(_ d: Duration) async { await Task.detached { try? await Task.sleep(for: d) }.value }
    }

    /// Sol 0.5.0 #2: the chosen mic is unplugged between the controller resolving it and the Recorder opening it. With an
    /// injected open failure the Recorder falls back to a fresh engine on the system default and reports the notice; the
    /// controller shows it in the pill and keeps the saved choice. No device is opened and nothing is captured.
    private static func checkMicFallback() async -> Bool {
        let recorder = Recorder()
        recorder.microphoneUID = "talkread-selftest-unplugged"
        var tried: [String] = []
        recorder.selectDevice = { uid, _ in tried.append(uid); return false }
        let (_, notice) = recorder.makeEngine()
        let opened = tried == ["talkread-selftest-unplugged"] && notice == Microphone.fallbackNotice(Microphone.inputs())
            && recorder.microphoneUID == "talkread-selftest-unplugged"

        // Sol verification 8: selected, then gone before it started. The attempt is cleaned up and the opening runs once
        // more on a fresh default engine, with the notice; once only, and never for the system default itself.
        let late = Recorder()
        late.microphoneUID = "talkread-selftest-late"
        late.selectDevice = { _, _ in true }
        var engines: [ObjectIdentifier] = []
        late.startInput = { engine, _ in engines.append(ObjectIdentifier(engine)); if engines.count == 1 { throw RecorderError.noDevice } }
        let retried = (try? late.openInput(session: 1)) != nil && engines.count == 2 && engines[0] != engines[1]
            && late.fallbackNotice == Microphone.fallbackNotice(Microphone.inputs()) && late.microphoneUID == "talkread-selftest-late"
        engines = []
        late.startInput = { engine, _ in engines.append(ObjectIdentifier(engine)); throw RecorderError.noDevice }
        let once = (try? late.openInput(session: 2)) == nil && engines.count == 2
        engines = []
        late.microphoneUID = nil
        let defaultOnce = (try? late.openInput(session: 3)) == nil && engines.count == 1 && late.fallbackNotice == nil
        let lateOK = retried && once && defaultOnce

        let audio = FakeAudio()
        audio.fallbackNotice = "Mic not found, using Selftest Default"
        let c = DictationController(audio: audio, asr: FakeASR()) { _, _, _, _ in .inserted }
        c.quiet = true
        let saved = Microphone.inputs().first?.uid ?? "talkread-selftest-mic"   // resolves now (read only), fails to open
        c.microphoneUID = saved
        try? c.start(caller: "A")
        let deadline = Date().addingTimeInterval(3)
        while c.micNotice != audio.fallbackNotice, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let shown = c.micNotice == audio.fallbackNotice && c.microphoneUID == saved && audio.starts == 1
        try? c.cancel(caller: "A")
        _ = await c.result()
        print("mic fallback: Recorder tried the saved mic and fell back with \"\(notice ?? "no notice")\" \(opened ? "ok" : "FAIL"); "
              + "selected then gone before starting: retried once on a fresh default engine \(retried ? "ok" : "FAIL"), "
              + "never twice \(once ? "ok" : "FAIL"), not for the default \(defaultOnce ? "ok" : "FAIL"); "
              + "pill shows \"\(c.micNotice ?? audio.fallbackNotice ?? "")\" while recording, saved choice kept \(shown ? "ok" : "FAIL")")
        return opened && lateOK && shown
    }

    private static func checkOwnership(fixture dir: URL) async -> Bool {
        var typed: [String] = [], targets: [pid_t?] = []
        let audio = FakeAudio()
        let c = DictationController(audio: audio, asr: FakeASR()) { text, pid, _, isCurrent in
            guard isCurrent() else { return .failed("Cancelled") }
            typed.append(text)
            targets.append(pid)
            return .inserted
        }
        c.quiet = true
        let user = DictationController.user
        var failures: [String] = []
        func expect(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        func busy(_ name: String, _ owner: String = "A", _ body: () throws -> Void) {
            do { try body(); failures.append("\(name): no busy") } catch { expect(name, error as? DictationError == .busy(owner: owner)) }
        }
        func settle(_ ms: Int = 100) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func recording() -> Bool { if case .recording = c.state { true } else { false } }
        /// Stops the human's utterance and returns its typed text; nil at once when the human does not hold a recording
        /// (a lost slot leaves a recording nobody can stop: the check must fail, not hang).
        func stopHuman() async -> String? {
            guard c.owner == user, recording() else { return nil }
            c.handle(.stopAndInsert)
            return await c.result()
        }
        let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "wav" }

        try? c.start(caller: "A")
        expect("A owns", c.owner == "A" && c.isBusy)
        busy("B start") { try c.start(caller: "B") }
        busy("B stop") { try c.stop(insert: true, caller: "B") }
        busy("B cancel") { try c.cancel(caller: "B") }
        if let file {
            do { _ = try await c.transcribe(file: file, caller: "B"); failures.append("B file: no busy") } catch {
                expect("B file busy", error as? DictationError == .busy(owner: "A"))
            }
        }
        await settle()                                              // A's microphone is on
        try? c.stop(insert: true, caller: "A")
        let first = await c.result()
        expect("A's stop inserts", first == "Utterance 1" && typed == ["Utterance 1"] && c.owner == nil && !c.isBusy)   // after Cleanup

        try? c.start(caller: "A")
        try? c.start(caller: "B", force: true)
        expect("forced takeover", c.owner == "B")
        try? c.cancel(caller: "B")
        expect("cancel releases", c.owner == nil && c.state == .idle)

        try? c.start(caller: "A")
        c.handle(.startRecording)                                   // the human's hold key during A's dictation
        expect("user wins", c.owner == user)
        await settle()
        let human = await stopHuman()
        expect("only the human's text is typed", human != nil && typed.count == 2 && typed.last == human)

        if let file {
            let a = Task { try await c.transcribe(file: file, caller: "A") }
            await Task.yield()                                      // A has reserved the slot before its first await
            do { _ = try await c.transcribe(file: file, caller: "B"); failures.append("second file: no busy") } catch {
                expect("second file busy", error as? DictationError == .busy(owner: "A"))
            }
            expect("first file completes", (try? await a.value) != nil && c.owner == nil)
        }
        expect("history newest first", c.history.first?.text == human)
        if let id = c.history.first?.id {
            c.delete(id)
            let onDisk = (try? JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: Paths.history))) ?? []
            expect("delete", !c.history.contains { $0.id == id } && onDisk.map(\.id) == c.history.map(\.id))
        }

        // #17: a history entry typed again through the guarded insert path, to the given process only.
        if let entry = c.history.first {
            let again = await c.reinsert(entry.id, targetPID: 4242)
            expect("reinsert", again == .inserted && typed.last == entry.text && targets.last == 4242 && !c.isBusy)
            expect("reinsert of a deleted entry fails", await c.reinsert(UUID(), targetPID: nil) != .inserted)
        }

        // #1: the microphone is never started, or left running, for a cancelled or stopped utterance, and a stale
        // startup never touches the newer utterance's input.
        var starts = audio.starts
        try? c.start(caller: "A")
        try? c.cancel(caller: "A")                                  // before its startup task ran
        await settle()
        expect("#1 cancel before startup: mic never started", audio.starts == starts && !audio.running && c.owner == nil)

        try? c.start(caller: "A")
        try? c.stop(insert: true, caller: "A")                      // before its startup task ran
        let early = await c.result()
        await settle()
        expect("#1 stop before startup: mic never started, nothing typed",
               audio.starts == starts && !audio.running && early == nil && c.owner == nil && c.state == .idle && typed.count == 3)

        try? c.start(caller: "A")
        c.handle(.startRecording)                                   // the human takes over before A's startup ran
        await settle()
        expect("#1 stale startup never asks for the mic", audio.starts == starts + 1 && audio.running && c.owner == user && recording())
        c.handle(.cancelRecording)
        expect("#1 cancel stops the mic", !audio.running && c.owner == nil)

        audio.delay = .milliseconds(150)
        starts = audio.starts
        try? c.start(caller: "A")
        await settle(40)                                            // A's microphone is starting
        try? c.cancel(caller: "A")
        await settle(250)
        expect("#1 cancel during startup: mic off", audio.starts == starts + 1 && !audio.running && c.owner == nil)

        try? c.start(caller: "A")
        await settle(40)                                            // A's microphone is starting ...
        c.handle(.startRecording)                                   // ... when the human takes over
        await settle(300)
        expect("#1 A's failed startup leaves the human's mic running", audio.running && c.owner == user && recording())
        let human2 = await stopHuman()
        expect("#1 the human's text is typed", human2 != nil && typed.last == human2 && !audio.running)
        audio.delay = .zero

        // #6: live dictation and file transcription share one slot; the human's start cancels the file job, and the
        // cancelled job never releases the human's slot.
        if let file {
            let a = Task { try await c.transcribe(file: file, caller: "A") }
            await Task.yield()
            expect("#6 the file job owns the slot", c.owner == "A" && c.isBusy)
            busy("#6 live start during a file") { try c.start(caller: "B") }
            busy("#6 own live start during its file") { try c.start(caller: "A") }
            c.handle(.startRecording)
            expect("#6 the human takes over the file", c.owner == user && recording())
            let taken = await a.result
            expect("#6 the taken-over file reports busy", { if case .failure(let e) = taken { e as? DictationError == .busy(owner: user) } else { false } }())
            expect("#6 the old file job leaves the human's slot alone", c.owner == user && recording())
            await settle()
            let human3 = await stopHuman()
            expect("#6 the human's text is typed", human3 != nil && typed.last == human3 && c.owner == nil && !c.isBusy)
        }

        // #19: hotkeys paused for the shortcut recorder, or reloaded, during a hold recording. The release is then
        // ignored (paused) or no longer tracked (reloaded), so the recording must be cancelled first: mic off, nothing
        // typed. The tap is never started; raw key data goes straight to the main-thread handler.
        let keys = Hotkeys(settings: Settings()) { c.handle($0) }
        let ropt = Hotkeys.option | Hotkeys.rightOptionDeviceBit
        let interruptions: [(String, () -> Void)] = [("pause", { keys.paused = true }), ("reload", { keys.reload(Settings()) })]
        for (name, interrupt) in interruptions {
            let before = typed.count
            keys.process(.flagsChanged, keyCode: Hotkeys.rightOptionKeyCode, flags: ropt, at: ProcessInfo.processInfo.systemUptime)
            await settle(300)                                       // held alone past 150 ms: the human is recording
            let wasRecording = c.owner == user && recording() && audio.running
            interrupt()
            keys.process(.flagsChanged, keyCode: Hotkeys.rightOptionKeyCode, flags: 0, at: ProcessInfo.processInfo.systemUptime)
            keys.paused = false
            await settle(200)
            expect("#19 \(name) during a hold recording: mic off, nothing typed",
                   wasRecording && !audio.running && c.owner == nil && c.state == .idle && typed.count == before)
            try? c.cancel(caller: user)                             // a failed check leaves nothing for the next one
        }

        // #2: an utterance cancelled while its text waits for the pasteboard is never pasted (the real Inserter on a
        // private pasteboard; another transaction holds the gate meanwhile; nothing is posted).
        if CGPreflightPostEventAccess() {
            let pb = NSPasteboard(name: NSPasteboard.Name("com.juniornkanabassi.talkread.selftest.dictation.\(getpid())"))
            let saved = Inserter.gate
            Inserter.gate = PasteboardGate(pasteboard: pb)
            var results: [InsertResult] = []
            let real = DictationController(audio: FakeAudio(), asr: FakeASR()) { text, _, _, isCurrent in
                let r = await Inserter.insert(text, targetPID: getpid(), isCurrent: isCurrent)
                results.append(r)
                return r
            }
            real.quiet = true
            let (release, releaseFeed) = AsyncStream.makeStream(of: Void.self)
            let holder = Task { await Inserter.gate.transaction { for await _ in release {} } }
            await settle(40)
            let before = pb.changeCount
            try? real.start(caller: "A")
            await settle()
            try? real.stop(insert: true, caller: "A")
            await settle(250)                                       // transcribed; the paste is waiting for the gate
            try? real.cancel(caller: "A")
            releaseFeed.finish()
            await holder.value
            let pasted = await real.result()
            expect("#2 cancelled while waiting for the pasteboard: not pasted",
                   pasted == nil && results.count == 1 && results.first != .inserted && pb.changeCount == before)

            // Quitting (FIX2-B #20): the closed gate refuses the write, so the insert fails at once and the pasteboard
            // keeps its sentinel (a ⌘V here would paste the user's own clipboard; the --insert panel checks none lands).
            let closed = PasteboardGate(pasteboard: pb)
            await closed.shutdown(grace: 0)
            Inserter.gate = closed
            pb.clearContents()
            pb.setString("talkread-quit-sentinel", forType: .string)
            let kept = pb.changeCount
            let quitting = await Inserter.insert("said while quitting", targetPID: getpid())
            expect("quit: insert refused, pasteboard untouched",
                   quitting == .failed("Talk & Read is quitting") && pb.changeCount == kept && pb.string(forType: .string) == "talkread-quit-sentinel")
            Inserter.gate = saved
            pb.releaseGlobally()
        } else {
            print("ownership: #2 paste-after-cancel check NOT RUN (no Accessibility)")
        }
        print("ownership: \(failures.isEmpty ? "ok" : "FAIL \(failures)") (typed \(typed))")
        return failures.isEmpty
    }

    // MARK: Drain and idle unload (Sol #23, #24) with the production recogniser queue

    private static func checkDrain(fixture dir: URL) async -> Bool {
        guard let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "wav" }) else { print("drain: NOT RUN (no wav in \(dir.path))"); return false }
        var events: [String] = [], typed: [String] = [], failures: [String] = []
        let audio = FakeAudio(), asr = FakeASR()
        audio.log = { events.append($0) }
        asr.log = { events.append($0) }
        asr.work = .milliseconds(100)
        // A decode that takes 300 ms, so a takeover can land inside it.
        let c = DictationController(audio: audio, asr: asr, insert: { text, _, _, _ in typed.append(text); return .inserted },
                                    decode: { Thread.sleep(forTimeInterval: 0.3); return try Transcriber.samples(of: $0) })
        c.quiet = true
        let user = DictationController.user
        func expect(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func waitUntil(_ condition: () -> Bool) async { for _ in 0..<200 where !condition() { await settle(10) } }
        func recording() -> Bool { if case .recording = c.state { true } else { false } }
        func stopHuman() async -> String? {
            guard c.owner == user, recording() else { return nil }
            c.handle(.stopAndInsert)
            return await c.result()
        }

        // #23: the human takes over a file mid-recognition. The slot is theirs at once, but the microphone starts only
        // after the cancelled file has left the recogniser.
        let a = Task { try await c.transcribe(file: file, caller: "A") }
        await waitUntil { asr.entered == 1 }
        await settle(30)                                            // inside an uninterruptible 100 ms step
        events.removeAll()
        c.handle(.startRecording)
        await settle(20)
        expect("#23 slot reserved, mic waits for the drain", c.owner == user && recording() && c.isBusy && c.preparing && !audio.running)
        _ = await a.result
        await waitUntil { audio.running }
        let exit = events.firstIndex(of: "exit") ?? .max, mic = events.firstIndex(of: "mic") ?? -1
        expect("#23 mic only after the cancelled file left the recogniser (\(events))", exit < mic && audio.running)
        let human = await stopHuman()
        expect("#23 the human's text is typed", human != nil && typed.last == human && !c.isBusy)

        // #23: the human takes over a file while it is still decoding: the microphone waits for the decode, and the
        // decoded file never enters the recogniser.
        let entered = asr.entered
        _ = Task { try await c.transcribe(file: file, caller: "B") }
        await settle(100)                                           // B is decoding
        c.handle(.startRecording)
        await settle(50)
        expect("#23 mic waits for the cancelled decode", c.owner == user && c.isBusy && !audio.running)
        // Not `await b.result`: a cancelled file that queued behind the human's run would deadlock with the drain.
        await waitUntil { audio.running }
        await settle(50)
        expect("#23 the cancelled file never entered the recogniser", asr.entered == entered + 1 && audio.running)   // + the human's
        let human2 = await stopHuman()
        expect("#23 the human's text is typed after a decode drain", human2 != nil && typed.last == human2)

        // #24: a cancelled file keeps the controller busy (and the unload refused) until it has drained.
        let d = Task { try await c.transcribe(file: file, caller: "D") }
        await waitUntil { asr.entered == entered + 2 }
        await settle(30)
        try? c.cancel(caller: "D")
        expect("#24 busy while the cancelled file drains", c.owner == nil && c.isBusy && !c.unloadModel() && asr.isLoaded)
        _ = await d.result
        await waitUntil { !c.isBusy }
        expect("#24 idle after the drain, then the unload succeeds", !c.isBusy && c.unloadModel() && !asr.isLoaded)

        // #24: a cold load outlives the cancelled file that started it: busy, unload refused, until the load ends.
        asr.loadTime = .milliseconds(600)
        let e = Task { try await c.transcribe(file: file, caller: "E") }
        await waitUntil { asr.isLoading }
        await settle(30)
        try? c.cancel(caller: "E")
        _ = await e.result
        await settle(30)
        expect("#24 busy while the abandoned load runs on", c.owner == nil && c.isBusy && asr.isLoading && !c.unloadModel())
        await waitUntil { !asr.isLoading }
        await settle(10)
        expect("#24 idle once the load ends, then the unload succeeds", !c.isBusy && asr.isLoaded && c.unloadModel() && !asr.isLoaded)

        print("drain: \(failures.isEmpty ? "ok" : "FAIL \(failures)") (typed \(typed))")
        return failures.isEmpty
    }

    // MARK: ASR fixtures

    private static func checkASR(dir: URL) async -> Bool {
        let clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wav", "m4a"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !clips.isEmpty else { print("asr: no clips in \(dir.path)"); return false }
        let transcriber = Transcriber()
        let started = Date()
        // #23/#24 on the real recogniser: unloading is refused while it loads, a cancelled waiter returns at once and
        // the load carries on, and unloading is refused while a run holds it.
        let waiter = Task { try await transcriber.load(progress: nil) }
        while !transcriber.isLoading, !transcriber.isLoaded { try? await Task.sleep(for: .milliseconds(1)) }
        let refusedLoading = transcriber.isLoading && !transcriber.unload()
        let cancelledAt = Date()
        waiter.cancel()
        let cancelled = await waiter.result
        let waiterMs = Date().timeIntervalSince(cancelledAt) * 1000
        let quit = { if case .failure(let e) = cancelled { e is CancellationError } else { false } }() && waiterMs < 100 && transcriber.isLoading
        do { try await transcriber.load(progress: nil) } catch { print("asr: model failed to load: \(error)"); return false }
        print(String(format: "asr: model ready in %.1f s (%@)", Date().timeIntervalSince(started), Transcriber.variant.rawValue))
        let (held, holdFeed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        let holding = Task { try await transcriber.run(held, partial: { _ in }) }
        try? await Task.sleep(for: .milliseconds(100))
        let refusedInUse = !transcriber.unload() && transcriber.isLoaded
        holding.cancel()
        let heldResult = await holding.result
        holdFeed.finish()
        let cancelledRun = { if case .failure(let e) = heldResult { e is CancellationError } else { false } }()
        let api = refusedLoading && quit && refusedInUse && cancelledRun
        print(String(format: "asr: unload refused while loading %@, while in use %@; cancelled load waiter returned in %.0f ms with the load carrying on %@; cancelled run ended %@",
                     "\(refusedLoading)", "\(refusedInUse)", waiterMs, "\(quit)", "\(cancelledRun)"))
        let controller = DictationController(audio: FakeAudio(), asr: transcriber, insert: { _, _, _, _ in .inserted })
        controller.quiet = true
        var fileErrors = 0, liveErrors = 0, words = 0
        var latencies: [Double] = []
        print("clip\tsec\tWER file\tWER live\tlatency ms\ttext (file)")
        for clip in clips {
            guard let reference = try? String(contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8),
                  let samples = try? Transcriber.samples(of: clip) else { print("\(clip.lastPathComponent)\tunreadable"); return false }
            // Written-form neutral (V-F): "the 14th of November at 3 pm" and "14 November at 3pm", "250 pounds" and
            // "£250" are the same words; formatting is scored by the hard set's key terms instead.
            let ref = DictationBench.lenient(reference)
            do {
                let fileText = try await controller.transcribe(file: clip, caller: "selftest")
                let (liveRaw, ms) = try await live(samples, transcriber)
                let liveText = Cleanup.apply(liveRaw, vocabulary: [:], removeFillers: true)
                let fe = editDistance(ref, DictationBench.lenient(fileText)), le = editDistance(ref, DictationBench.lenient(liveText))
                fileErrors += fe; liveErrors += le; words += ref.count
                latencies.append(ms)
                print(String(format: "%@\t%.1f\t%.1f%%\t%.1f%%\t%.0f\t%@", clip.deletingPathExtension().lastPathComponent,
                             Double(samples.count) / 16_000, 100 * Double(fe) / Double(ref.count),
                             100 * Double(le) / Double(ref.count), ms, fileText))
                if le > 0, liveText != fileText { print("\t\t\t\t\tlive: \(liveText)") }
            } catch {
                print("\(clip.lastPathComponent)\tfailed: \(error)")
                return false
            }
        }
        let fileWER = Double(fileErrors) / Double(words), liveWER = Double(liveErrors) / Double(words)
        let sorted = latencies.sorted()
        print(String(format: "asr: %d clips, %d words; total WER file %.2f%%, live %.2f%% (limit 6%%); latency after last sample median %.0f ms, max %.0f ms",
                     clips.count, words, 100 * fileWER, 100 * liveWER, sorted[sorted.count / 2], sorted.last!))
        let paragraphs = await checkParagraphs(transcriber, clips: clips)
        let unloaded = controller.unloadModel() && !transcriber.isLoaded
        print("asr: unloaded when idle \(unloaded)")
        return fileWER <= 0.06 && liveWER <= 0.06 && api && unloaded && paragraphs
    }

    // MARK: Paragraphs (F-A, F12)

    /// Four paragraphs of 3, 5, 4 and 5 sentences for Kokoro to speak: their starts (sentences 4, 9 and 13) are not where the
    /// every-five-sentences fallback would cut (6, 11 and 16), so only the real pauses can put the breaks there. No spoken
    /// list words or commands in it.
    private static let script = [
        ["Welcome back to the channel and thanks for joining me today.",
         "I want to talk about why this season's title race is much closer than anyone expected.",
         "At the start of the year, almost every pundit picked one club to run away with it."],
        ["One reason is the fixture list, which has been far kinder to the chasing pack.",
         "The leaders have already played most of the toughest away games on their calendar.",
         "Meanwhile their rivals have enjoyed a run of home matches against teams in the bottom half.",
         "Over time those easier weeks will balance out, but right now they matter.",
         "Points banked early are worth just as much as points won in May."],
        ["Injuries have also played a huge part in the story.",
         "The champions lost their captain for six weeks after a clumsy tackle in training.",
         "Their main rivals, on the other hand, have barely lost a single starter.",
         "Squad depth is usually what decides a long campaign like this one."],
        ["So where does that leave us as we head into the winter break?",
         "I expect at least three clubs to stay in contention until the final weeks.",
         "The pressure will build, and that is when mistakes start to appear.",
         "If you enjoyed this video, please subscribe and leave a comment with your prediction.",
         "Thanks for watching, and I will see you in the next one."]
    ]

    /// `script` spoken by Kokoro at 1x, one sentence at a time with its silent edges trimmed, 0.4 s between sentences and
    /// 1.2 s between paragraphs (known gaps), as 16 kHz samples.
    private static func speak(_ script: [[String]], with kokoro: NeuralEngine) async throws -> [Float] {
        try await kokoro.prepare(voice: "af_heart")
        var out: [Float] = []
        for paragraph in script {
            for (s, sentence) in paragraph.enumerated() {
                let chunk = try await kokoro.synthesize(sentence, voice: "af_heart")
                let (rms, floor, hop) = Aligner.frames(chunk.samples, sampleRate: chunk.sampleRate)
                let from = (rms.firstIndex { $0 >= floor } ?? 0) * hop, to = min(((rms.lastIndex { $0 >= floor } ?? 0) + 1) * hop, chunk.samples.count)
                let speech = try AudioConverter().resample(Array(chunk.samples[from..<max(from, to)]), from: chunk.sampleRate)
                if !out.isEmpty { out += [Float](repeating: 0, count: Int(16_000 * (s == 0 ? 1.2 : 0.4))) }
                out += speech
            }
        }
        return out
    }

    /// The first three words of each paragraph, for comparing where paragraphs start.
    private static func starts(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { normalised($0).prefix(3).joined(separator: " ") }
    }

    /// The Parakeet dictation path (file route, no microphone) on a Kokoro-spoken script of unequal paragraphs: the breaks
    /// land at the script's paragraph starts (one mistake allowed, a miss or an extra break) and the same text without its
    /// pauses breaks elsewhere, so the pauses drive it; `split` + `tidy` take under 5 ms; a short dictation equals the
    /// cleaned baseline exactly; and the release-to-insertion latency through the whole controller grows by at most 10 ms.
    private static func checkParagraphs(_ transcriber: Transcriber, clips: [URL]) async -> Bool {
        guard NeuralEngine.modelInstalled() else { print("paragraphs: NOT RUN (the Kokoro voice is not installed)"); return false }
        guard Paths.dataRoot.path.hasPrefix("/private/tmp") else { print("paragraphs: NOT RUN (data root is not a scratch folder)"); return false }
        let kokoro = NeuralEngine()
        let samples: [Float]
        do { samples = try await speak(script, with: kokoro) } catch { print("paragraphs: could not speak the script: \(error)"); return false }
        kokoro.unload()
        func dictate(_ samples: [Float]) async throws -> String {
            let controller = DictationController(audio: FakeAudio(), asr: transcriber, insert: { _, _, _, _ in .inserted }, decode: { _ in samples })
            controller.quiet = true
            return try await controller.transcribe(file: URL(fileURLWithPath: "/dev/null"), caller: "selftest")
        }
        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let text = try await dictate(samples)
            let expected = starts(script.map { $0[0] }.joined(separator: "\n\n")), found = starts(text)
            let missed = expected.dropFirst().filter { !found.contains($0) }.count, extra = found.dropFirst().filter { !expected.contains($0) }.count
            let blind = starts(Paragraphs.split(raw.text, pauses: []))
            let drives = blind != starts(Paragraphs.split(raw.text, pauses: raw.pauses))
            let clean = Cleanup.apply(Paragraphs.split(raw.text, pauses: raw.pauses), vocabulary: [:], removeFillers: true)
            let began = Date()
            for _ in 0..<200 { _ = Paragraphs.tidy(Cleanup.apply(Paragraphs.split(raw.text, pauses: raw.pauses), vocabulary: [:], removeFillers: true)) }
            let withCleanup = Date().timeIntervalSince(began) * 1000 / 200
            let began2 = Date()
            for _ in 0..<200 { _ = Paragraphs.tidy(Paragraphs.split(raw.text, pauses: raw.pauses)) }
            let splitMs = Date().timeIntervalSince(began2) * 1000 / 200
            print("paragraphs: \(script.joined().joined(separator: " ").split(separator: " ").count) words in \(script.map(\.count)) sentences (gaps 1.2 s before sentences 4, 9, 13, else 0.4 s); the recogniser heard \(raw.pauses.count) sentences, pause before each: " +
                  raw.pauses.map { $0.map { String(format: "%.2f", $0) } ?? "?" }.joined(separator: ", "))
            print("paragraphs: \(text.components(separatedBy: "\n\n").count) paragraphs, missed \(missed), extra \(extra); without pauses the paragraphs start at \(blind.dropFirst().joined(separator: " | ")) (differs: \(drives))")
            print("paragraphs: split + tidy \(String(format: "%.3f", splitMs)) ms (with Cleanup \(String(format: "%.3f", withCleanup)) ms) on \(clean.count) characters")
            print("paragraphs output: " + text.replacingOccurrences(of: "\n\n", with: " ⏎⏎ "))
            let rawShort = try await transcriber.transcribe(samples: Array(samples.prefix(16_000 * 8)))
            let baseline = BritishSpelling.apply(Cleanup.apply(rawShort.text, vocabulary: [:], removeFillers: true, isWord: DictationController.isCommonWord))
            let short = try await dictate(Array(samples.prefix(16_000 * 8)))
            print("paragraphs: short dictation (8 s) \"\(short)\" equals the cleaned baseline: \(short == baseline)")
            // Release to insertion through the production controller, paragraphs off and on (the same clips, one binary).
            var settings = Settings.load()
            let saved = settings.paragraphs
            defer { settings.paragraphs = saved; try? settings.save() }
            settings.paragraphs = true; try? settings.save()
            let on = await DictationBench.releaseToPaste(transcriber, clips: clips)
            settings.paragraphs = false; try? settings.save()
            let off = await DictationBench.releaseToPaste(transcriber, clips: clips)
            let measured = on.count > 0 && on.count == on.tried && off.count > 0 && off.count == off.tried
            let slow = !measured || on.median - off.median > 10 || on.median > 50
            print(String(format: "paragraphs: release to insertion median %.0f ms (max %.0f) over %d of %d insertions with paragraphs, %.0f ms (max %.0f) over %d of %d without; 0.5.0 was 25 to 40 ms%@",
                         on.median, on.max, on.count, on.tried, off.median, off.max, off.count, off.tried, measured ? (slow ? "  TOO SLOW" : "") : "  FAIL: not every insertion was measured"))
            let regressions = checkSplitRegressions()
            return missed + extra <= 1 && drives && splitMs < 5 && short == baseline && !slow && text.hasSuffix(".") && regressions
        } catch {
            print("paragraphs: failed: \(error)")
            return false
        }
    }

    /// Sol's 0.6.0 findings 1, 2 and 5 to 7 on the pure code: no break inside "Dr. Smith", "No. 5", an ellipsis or a French
    /// quotation; pauses stay with their sentence through filler and repeated sentence starts; lists stay whole.
    private static func checkSplitRegressions() -> Bool {
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima"]
        let plain = { (n: String) in "\(n) goes with eight other plain words to make ten." }
        func around(_ middle: String) -> String { (names.prefix(4).map(plain) + [middle] + names[4..<7].map(plain)).joined(separator: " ") }
        var failures: [String] = []
        for (label, middle, bad) in [("Dr.", "Please ask Dr. Smith about the plan before noon today.", "Dr.\n\n"),
                                     ("No. 5", "We live at No. 5 on the left side of the road.", "No.\n\n"),
                                     ("ellipsis", "I thought... perhaps we should wait until the weekend instead.", "...\n\n"),
                                     ("guillemets", "Il a répondu « oui ! » Ensuite nous sommes partis ensemble.", "!\n\n»")] {
            let out = Paragraphs.split(around(middle))
            if out.contains(bad) || !out.contains(label == "guillemets" ? "« oui ! »" : middle) { failures.append(label) }
        }
        let um = (0..<8).map { $0 >= 1 && $0 <= 3 ? "Um, bit \(names[$0]) goes with eight other plain words to make ten." : plain(names[$0]) }
        let gaps = { (at: Int) in (0..<8).map { $0 == 0 ? nil : ($0 == at ? 1.3 : 0.2) as Double? } }
        let split = Paragraphs.split(um.joined(separator: " "), pauses: gaps(4))
        if !Cleanup.apply(split, vocabulary: [:], removeFillers: true).contains("\n\n" + plain("Echo")) { failures.append("Um, starts") }
        let so = (0..<8).map { "So, " + plain(names[$0]).lowercased() }
        if !Paragraphs.split(so.joined(separator: " "), pauses: gaps(5)).contains("\n\nSo, foxtrot goes") { failures.append("repeated starts") }
        let list = Paragraphs.tidy((1...62).map { "w\($0)" }.joined(separator: " ") + ".\n1. One thing.\n\n2. Two things")
        if !list.hasSuffix("\n1. One thing.\n2. Two things.") { failures.append("list") }
        // An explicit list item that runs on (split, Cleanup, tidy as the app does): no blank line inside it.
        let item = (0..<7).map { plain(names[$0]) }.joined(separator: " ")
        let doc = "Here is the plan for today. It has a few parts.\n- " + item
        let end = Paragraphs.tidy(Cleanup.apply(Paragraphs.split(doc), vocabulary: [:], removeFillers: true))   // no pauses: the 5-sentence fallback
        if !end.contains("\n- " + item) { failures.append("list item continues") }
        print("paragraphs: Sol regressions (Dr., No. 5, ellipsis, guillemets, Um starts, repeated starts, lists, a list item that runs on, full stop) \(failures.isEmpty ? "ok" : "FAIL \(failures)")")
        return failures.isEmpty
    }

    /// The live path: the clip re-sampled to a typical 48 kHz stereo input format, through the Recorder's converter in
    /// 100 ms buffers at real-time pace into a streaming run. Returns the text and ms from the last sample to the result.
    static func live(_ samples: [Float], _ transcriber: DictationASR) async throws -> (String, Double) {
        let hardware = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let source = Transcriber.buffer(samples[...])
        guard let up = AVAudioConverter(from: StreamConverter.format, to: hardware),
              let input = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: AVAudioFrameCount(samples.count * 3 + 4800)),
              let recorder = StreamConverter(from: hardware) else { throw RecorderError.noDevice }
        var fed = false
        _ = up.convert(to: input, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        let result = Task { try await transcriber.run(stream, partial: { _ in }).text }
        let total = Int(input.frameLength)
        for start in stride(from: 0, to: total, by: 4800) {
            if start > 0 { try await Task.sleep(for: .milliseconds(100)) }   // the next 100 ms being "spoken"
            let count = min(4800, total - start)
            let slice = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: AVAudioFrameCount(count))!
            slice.frameLength = AVAudioFrameCount(count)
            for ch in 0..<2 { slice.floatChannelData![ch].update(from: input.floatChannelData![ch] + start, count: count) }
            if let converted = recorder.convert(slice) { feed.yield(converted) }
        }
        let lastSample = Date()                                          // key released right after the last buffer
        feed.finish()
        let text = try await result.value
        return (text, Date().timeIntervalSince(lastSample) * 1000)
    }

    /// Case and punctuation removed: dots and apostrophes join ("p.m." = "pm", "I'll" = "ill"), other punctuation
    /// separates; "%" is "percent". Nothing else (no number or spelling normalisation).
    static func normalised(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "[.'’]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    /// Word-level Levenshtein distance (substitutions + insertions + deletions).
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for i in a.indices {
            var diagonal = row[0]
            row[0] = i + 1
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = a[i] == b[j] ? diagonal : 1 + min(diagonal, above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: Insertion (--insert)

    private static func checkInsertion() async -> Bool {
        guard pthread_main_np() != 0 else {
            print("insert: NOT RUN (the main actor is not on the main thread: the --selftest dispatch must run the main run loop, not dispatchMain)")
            return false
        }
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains("Prompter") }) else {
            print("insert: NOT RUN (no Prompter XL screen)")
            return true
        }
        // Prohibited: the process can never be activated, so Junior's app keeps focus. The panel is never key.
        let app = NSApplication.shared
        guard app.setActivationPolicy(.prohibited) || app.activationPolicy() == .prohibited else {
            print("insert: NOT RUN (could not make the process non-activating)")
            return false
        }
        let focusBefore = focusedAppPID()
        // A private pasteboard: Junior's clipboard is never read or written.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.juniornkanabassi.talkread.selftest.insert.\(getpid())"))
        let savedGate = Inserter.gate
        Inserter.gate = PasteboardGate(pasteboard: pasteboard)
        defer {
            Inserter.gate = savedGate
            pasteboard.releaseGlobally()
        }

        // Key equivalents reach the Edit menu even though no window is key; Paste puts the private pasteboard's text
        // into the field under test (a text view reads it as its own paste does).
        let forwarder = PasteForwarder(pasteboard: pasteboard)
        let menu = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        let paste = edit.addItem(withTitle: "Paste", action: #selector(PasteForwarder.paste(_:)), keyEquivalent: "v")
        paste.target = forwarder
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        let size = NSSize(width: 420, height: 230)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        // AppKit may move a new window to the main screen at init: place it explicitly, check, and only then show it.
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        guard panel.screen?.localizedName.contains("Prompter") == true else {
            print("insert: NOT RUN (panel would land on \(panel.screen?.localizedName ?? "no screen"), not the Prompter XL)")
            return true
        }
        panel.backgroundColor = .windowBackgroundColor
        panel.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 186, width: 380, height: 24))
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 152, width: 380, height: 24))
        let web = WKWebView(frame: NSRect(x: 20, y: 20, width: 380, height: 120))
        for view in [field, secure, web] as [NSView] { panel.contentView?.addSubview(view) }
        field.stringValue = "Dear Sarah,"
        web.loadHTMLString("<textarea id='t' style='width:95%;height:90px'></textarea>", baseURL: nil)

        let pump = Task { @MainActor in                              // this run loop is not NSApp.run: deliver events here
            while !Task.isCancelled {
                if let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
                await Task.yield()
            }
        }
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))
        var failures: [String] = []
        if NSRunningApplication.current.isActive || panel.isKeyWindow || panel.screen != screen {
            failures.append("panel activated, became key or left the Prompter XL")
        }

        /// `cancelAtPaste`: the inserting task is cancelled the moment its last check passes, just before ⌘V goes out;
        /// the paste must still get its full wait (else the restored sentinel would be pasted instead).
        func attempt(_ text: String, cancelAtPaste: Bool = false) async -> (InsertResult, Bool) {
            let sentinel = "talkread-sentinel-\(UUID().uuidString)"
            let item = NSPasteboardItem()
            item.setString(sentinel, forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let result = await Task {
                await Inserter.insert(text, targetPID: getpid(), isCurrent: {
                    if cancelAtPaste { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                })
            }.value
            try? await Task.sleep(for: .milliseconds(150))
            return (result, pasteboard.string(forType: .string) == sentinel)
        }

        if failures.isEmpty {
            panel.makeFirstResponder(field)
            let editor = panel.firstResponder as? NSTextView
            editor?.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
            forwarder.target = editor
            let (r1, restored1) = await attempt("thanks for the update.")
            let got1 = field.stringValue
            print("insert: NSTextField \(r1) -> \"\(got1)\", pasteboard restored \(restored1)")
            if r1 != .inserted || got1 != "Dear Sarah, thanks for the update." || !restored1 { failures.append("NSTextField") }
            let started = Date()
            let (r1b, restored1b) = await attempt("See you soon.", cancelAtPaste: true)
            let waited = Date().timeIntervalSince(started), got1b = field.stringValue
            print(String(format: "insert: cancelled at ⌘V %@ -> \"%@\", waited %.0f ms, pasteboard restored %@", "\(r1b)", got1b, waited * 1000, "\(restored1b)"))
            if r1b != .inserted || got1b != "Dear Sarah, thanks for the update. See you soon." || waited < 0.5 || !restored1b {
                failures.append("cancelled at paste")
            }

            panel.makeFirstResponder(web)
            forwarder.target = web
            _ = try? await web.evaluateJavaScript("document.getElementById('t').focus()")
            let (r2, restored2) = await attempt("Meeting moved to Thursday at 3 pm.")
            let got2 = (try? await web.evaluateJavaScript("document.getElementById('t').value")) as? String ?? "?"
            print("insert: WKWebView textarea \(r2) -> \"\(got2)\", pasteboard restored \(restored2)")
            if r2 != .inserted || got2 != "Meeting moved to Thursday at 3 pm." || !restored2 { failures.append("textarea") }

            panel.makeFirstResponder(secure)
            forwarder.target = panel.firstResponder
            let (r3, restored3) = await attempt("my secret words")
            print("insert: NSSecureTextField \(r3) -> \(secure.stringValue.isEmpty ? "empty" : "NOT EMPTY"), pasteboard restored \(restored3)")
            if r3 != .refusedSecure || !secure.stringValue.isEmpty || !restored3 { failures.append("secure field") }

            // Quitting (FIX2-B #20): with the gate closed the write is refused and no ⌘V goes out, so the panel's
            // Paste never runs (it would have pasted the sentinel, i.e. the user's own clipboard).
            panel.makeFirstResponder(field)
            forwarder.target = panel.firstResponder
            let closed = PasteboardGate(pasteboard: pasteboard)
            await closed.shutdown(grace: 0)
            Inserter.gate = closed
            let pastes = forwarder.pastes, before4 = field.stringValue
            let (r4, restored4) = await attempt("said while quitting")
            try? await Task.sleep(for: .milliseconds(500))           // time for a stray ⌘V to arrive
            print("insert: gate closed for quit \(r4) -> pastes \(forwarder.pastes - pastes), field unchanged \(field.stringValue == before4), pasteboard kept \(restored4)")
            if r4 != .failed("Talk & Read is quitting") || forwarder.pastes != pastes || field.stringValue != before4 || !restored4 {
                failures.append("closed gate")
            }
        }
        panel.close()
        pump.cancel()
        await pump.value
        let focusAfter = focusedAppPID()
        if NSRunningApplication.current.isActive || focusAfter != focusBefore { failures.append("focus moved (\(focusBefore) -> \(focusAfter))") }
        // Read-only: what the AX path sees in Junior's frontmost app (nothing is typed there).
        let front = Inserter.focusedField(pid: nil)
        print("insert: frontmost app focus via AX (read only): secure \(front.secure), caret context \(front.previous != nil ? "found" : "none")")
        print("insert: \(failures.isEmpty ? "ok" : "FAIL \(failures)"); focus stayed with pid \(focusAfter)")
        return failures.isEmpty
    }

    /// The test panel's Edit ▸ Paste, reading the private pasteboard: a text view (or field editor) reads it as its
    /// own paste does; the web view's focused element gets the text inserted at its selection.
    @MainActor private final class PasteForwarder: NSObject {
        let pasteboard: NSPasteboard
        weak var target: NSResponder?
        private(set) var pastes = 0
        init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        @objc func paste(_ sender: Any?) {
            pastes += 1
            if let editor = target as? NSTextView {
                _ = editor.readSelection(from: pasteboard)
            } else if let web = target as? WKWebView, let text = pasteboard.string(forType: .string) {
                web.callAsyncJavaScript("const t = document.activeElement; t.setRangeText(text, t.selectionStart, t.selectionEnd, 'end')",
                                        arguments: ["text": text], in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    private static func focusedAppPID() -> pid_t {
        var value: CFTypeRef?
        var pid: pid_t = 0
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value { AXUIElementGetPid(value as! AXUIElement, &pid) }
        return pid
    }
}
