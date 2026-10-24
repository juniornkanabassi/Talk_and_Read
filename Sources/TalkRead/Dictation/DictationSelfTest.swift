// `TalkRead --selftest-asr <dir> [--insert]`: hotkey mapping, the ownership rules (fake recorder and recogniser),
// WER and latency of the real Transcriber over the fixtures (file path and live streaming path), and, with --insert,
// pasting into a test panel on the Prompter XL. Never uses the microphone; events go only to our own pid.
import AppKit
import AVFoundation
import TalkReadCore
import WebKit

@MainActor enum DictationSelfTest {
    static func run(dir: String) async -> Int32 {
        // History and settings go to a scratch home unless the caller chose one (never the real data root).
        if ProcessInfo.processInfo.environment["TALKREAD_HOME"] == nil {
            setenv("TALKREAD_HOME", "/private/tmp/talkread-selftest-home", 1)
        }
        if CommandLine.arguments.contains("--bench") { return await DictationBench.run(dir: URL(fileURLWithPath: dir)) }
        var ok = checkHotkeys()
        ok = checkTextRules() && ok
        if Paths.dataRoot.path.hasPrefix("/private/tmp") {
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
        let british = BritishSpelling.apply("The neighbor's color, center and organizer; email footballco.com or Footballco. Realize it.")
        let ok = flat == "Hi Jon, Thanks. 1. Trim the intro. 2. Send it" && !flat.contains("\n")
            && british == "The neighbour's colour, centre and organiser; email footballco.com or Footballco. Realise it."
            && Inserter.terminalApps.isSuperset(of: ["com.apple.Terminal", "com.googlecode.iterm2"])
        print("text: terminal paste one line \"\(flat)\"; British \"\(british)\" \(ok ? "ok" : "FAIL")")
        return ok
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

        func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> String {
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
                return "utterance \(count)"
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

        let audio = FakeAudio()
        audio.fallbackNotice = "Mic not found, using Selftest Default"
        let c = DictationController(audio: audio, asr: FakeASR()) { _, _, _ in .inserted }
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
              + "pill shows \"\(c.micNotice ?? audio.fallbackNotice ?? "")\" while recording, saved choice kept \(shown ? "ok" : "FAIL")")
        return opened && shown
    }

    private static func checkOwnership(fixture dir: URL) async -> Bool {
        var typed: [String] = [], targets: [pid_t?] = []
        let audio = FakeAudio()
        let c = DictationController(audio: audio, asr: FakeASR()) { text, pid, isCurrent in
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
            let real = DictationController(audio: FakeAudio(), asr: FakeASR()) { text, _, isCurrent in
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
        let c = DictationController(audio: audio, asr: asr, insert: { text, _, _ in typed.append(text); return .inserted },
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
        let controller = DictationController(audio: FakeAudio(), asr: transcriber, insert: { _, _, _ in .inserted })
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
        let unloaded = controller.unloadModel() && !transcriber.isLoaded
        print("asr: unloaded when idle \(unloaded)")
        return fileWER <= 0.06 && liveWER <= 0.06 && api && unloaded
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
        let result = Task { try await transcriber.run(stream, partial: { _ in }) }
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
