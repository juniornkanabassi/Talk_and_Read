// `TalkRead --selftest-control [clip.wav]`: drives the control handlers through the real socket and the real CLI.
// Headless (Junior, 21 Oct): no status item, windows or hotkeys, and reads use a silent engine, so nothing is heard.
import AppKit
import ServiceManagement
import TalkReadCore

/// Speaks silence, `secondsPerWord` per word, so a read stays live long enough to test ownership.
final class SilentEngine: SpeechEngine {
    let kind: EngineKind
    let secondsPerWord = 0.8
    init(kind: EngineKind) { self.kind = kind }

    func voices() async -> [Voice] {
        kind == .system ? [Voice(id: "silent", name: "Silent (test)", accent: "None", gender: "None", engine: .system, installed: true)] : []
    }
    func prepare(voice: String) async throws {}
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let words = TextKit.tokenize(text).enumerated().map { i, t in
            SpokenWord(text: t.text, start: Double(i) * secondsPerWord, end: Double(i + 1) * secondsPerWord, range: t.range)
        }
        let seconds = Double(max(words.count, 1)) * secondsPerWord
        return SynthChunk(samples: [Float](repeating: 0, count: Int(seconds * 24_000)), sampleRate: 24_000, words: words)
    }
    func unload() {}
}

enum ControlSelfTest {
    enum Expect { case ok, audio, busy, replayed, badArgs, unavailable }
    struct Outcome { let status: Int32; let response: ControlResponse?; let text: String }

    @MainActor static func run(clip: String?) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)   // one line at a time, also when piped
        guard let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], !home.isEmpty else {
            print("--selftest-control needs TALKREAD_HOME set to a disposable folder.")
            return 2
        }
        let dir = Bundle.main.executableURL!.deletingLastPathComponent()
        guard let cli = [dir.appendingPathComponent("TalkReadCLI"), dir.appendingPathComponent("../Helpers/talkread")]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            print("TalkReadCLI was not found next to \(dir.path).")
            return 2
        }
        let model = AppModel.shared
        model.engines = Engines(neural: SilentEngine(kind: .neural), system: SilentEngine(kind: .system))
        model.dictation.quiet = true   // no pill, no sounds
        await model.loadVoices()
        let server: ControlServer
        do { server = try ControlServer(path: Paths.controlSocket) { await AppModel.shared.handle($0) } } catch {
            print("Control server failed to start: \(error)")
            return 1
        }
        defer { server.stop() }
        print("control self-test: home \(home), CLI \(cli.path)")

        var results: [Bool] = []
        func step(_ label: String, _ args: [String], _ expect: Expect) async {
            results.append(check(label, await call(cli, args), expect))
        }
        await step("status", ["status"], .ok)
        await step("voices", ["voices"], .ok)
        await step("settings-get", ["settings-get"], .ok)
        await step("settings-set speed 1.5", ["settings-set", "speed", "1.5"], .ok)
        // 0.7.0: routed to Sparkle; a self-test starts no updater, so the answer is a clear error, never a window.
        await step("update-check (no updater here)", ["update-check"], .unavailable)
        await microphoneSteps(cli, model, &results)
        await historySteps(cli, model, &results)
        await step("a speak", ["speak", "Hello from the control test.", "--caller", "a"], .audio)
        await step("b speak while a reads", ["speak", "Interrupting.", "--caller", "b"], .busy)
        await step("b pause", ["pause", "--caller", "b"], .busy)
        await step("b speed 2", ["speed", "2", "--caller", "b"], .busy)
        await step("b voice", ["voice", "silent", "--caller", "b"], .busy)
        await step("b settings-set speed 2", ["settings-set", "speed", "2", "--caller", "b"], .busy)
        await step("b settings-set removeFillers false", ["settings-set", "removeFillers", "false", "--caller", "b"], .ok)
        await step("a pause", ["pause", "--caller", "a"], .ok)
        await step("b resume while a is paused", ["resume", "--caller", "b"], .busy)
        await step("a stop", ["stop", "--caller", "a"], .ok)
        let requestID = UUID().uuidString
        let again = ["speak", "Second caller now.", "--caller", "b", "--request-id", requestID]
        await step("b speak after a stopped", again, .audio)
        await step("b speak, same request id", again, .replayed)
        await step("b stop", ["stop", "--caller", "b"], .ok)

        // Documents: `open` imports into the library (copy + text beside it) without showing a window; `read-file` reads.
        let docs = URL(fileURLWithPath: "Tests/Fixtures/documents")
        let opened = await call(cli, ["open", docs.appendingPathComponent("sample.pdf").path, "--caller", "a"])
        results.append(check("a open sample.pdf", opened, .ok) && opened.response?.data?["shown"] == .bool(true))
        let item = model.library.first
        let copied = item.map { FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent($0.fileName).path) } ?? false
        let text = item.flatMap { try? model.documentText($0) } ?? ""
        let stored = item?.kind == "pdf" && copied && text.contains("Marlowe Quay")
        results.append(stored)
        print("\(stored ? "PASS" : "FAIL")  library: PDF copied as \(item?.fileName ?? "-"), text \(text.utf16.count) UTF-16 units")
        await step("a read-file sample.txt", ["read-file", docs.appendingPathComponent("sample.txt").path, "--caller", "a"], .audio)
        await step("b skip while a reads", ["skip", "--caller", "b"], .busy)
        // Sol #5: an absurd skip is refused before it reaches the session, and the app stays up.
        await step("a skip Int.max", ["skip", String(Int.max), "--caller", "a"], .badArgs)
        await step("a skip Int.min", ["skip", String(Int.min), "--caller", "a"], .badArgs)
        await step("a skip 10001", ["skip", "10001", "--caller", "a"], .badArgs)
        await step("a skip -2 (still reading)", ["skip", "-2", "--caller", "a"], .ok)
        await step("a stop", ["stop", "--caller", "a"], .ok)
        await librarySteps(cli, model, &results)
        await admissionSteps(cli, model, &results)
        await importReplaySteps(model, &results)
        await wordListSteps(cli, model, &results)

        // Two callers transcribe at once: the shared transcriber admits one, the other is told busy.
        // Sol #16: with a 1 s idle unload, nothing may be pending while the file keeps dictation busy; after it, the
        // unload is scheduled and fires.
        model.unloadDelay = .seconds(1)
        if let clip = clip ?? fixture() {
            let watch = Task { @MainActor () -> (busy: Bool, overlap: Bool) in
                var seen = (busy: false, overlap: false)
                while !Task.isCancelled {
                    if model.dictation.isBusy { seen.busy = true; if model.unloadPending { seen.overlap = true } }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return seen
            }
            async let first = call(cli, ["dictate-file", clip, "--caller", "a"])
            async let second = call(cli, ["dictate-file", clip, "--caller", "b"])
            let both = await [first, second]
            watch.cancel()
            let done = both.filter { $0.response?.ok == true && !($0.response?.data?["text"]?.stringValue ?? "").isEmpty }.count
            let busy = both.filter { $0.response?.code == "busy" }.count
            let pass = done == 1 && busy == 1
            print("\(pass ? "PASS" : "FAIL")  a and b dictate-file at once (one done, one busy)")
            for (who, o) in zip(["a", "b"], both) { print("      \(who): \(o.text)") }
            results.append(pass)
            let seen = await watch.value
            let loaded = model.dictation.asr.isLoaded, scheduled = model.unloadPending
            let unloaded = await waitUntil(3) { !model.unloadPending && !model.dictation.asr.isLoaded }
            let idle = seen.busy && !seen.overlap && loaded && scheduled && unloaded
            print("\(idle ? "PASS" : "FAIL")  idle unload around dictate-file: busy seen \(seen.busy), unload pending while busy \(seen.overlap), "
                  + "after: loaded \(loaded), scheduled \(scheduled), unloaded within 3 s \(unloaded)")
            results.append(idle)
        } else {
            print("FAIL  dictate-file: no clip given and no Tests/Fixtures/dictation/*.wav in the current folder")
            results.append(false)
        }
        // Sol #16: a finished download starts the idle countdown. Only when both models are installed (no network).
        if model.voiceModel == .ready, model.dictationModel == .ready {
            await step("models download (installed: no network)", ["models", "download"], .ok)
            let scheduled = model.unloadPending
            let fired = await waitUntil(3) { !model.unloadPending }
            print("\(scheduled && fired ? "PASS" : "FAIL")  idle unload after a download: scheduled \(scheduled), fired within 3 s \(fired)")
            results.append(scheduled && fired)
        } else {
            print("SKIP  idle unload after a download: a model is missing and the check must not download")
        }
        model.unloadDelay = nil
        model.stopReading()

        // Sol #4: quitting waits for the pasteboard gate's restore. A private pasteboard, never the user's clipboard.
        let board = NSPasteboard(name: NSPasteboard.Name("talkread-fix1d-quit-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("the user's clipboard", forType: .string)
        let gate = PasteboardGate(pasteboard: board)
        let paste = Task { await gate.transaction { gate.write("dictated text"); try? await Task.sleep(for: .milliseconds(400)) } }
        try? await Task.sleep(for: .milliseconds(100))
        let during = board.string(forType: .string)
        let quitStart = Date()
        await gate.shutdown(grace: 3)                               // what applicationShouldTerminate awaits
        let atQuit = board.string(forType: .string)
        let waited = Int(Date().timeIntervalSince(quitStart) * 1000)
        await paste.value
        board.releaseGlobally()
        let quitOK = during == "dictated text" && atQuit == "the user's clipboard"
        print("\(quitOK ? "PASS" : "FAIL")  quit during a paste: clipboard during \"\(during ?? "-")\", at quit \"\(atQuit ?? "-")\" after \(waited) ms")
        results.append(quitOK)

        // Sol #17: "Insert again" targets the app that comes forward once Talk & Read hides (never itself).
        let t17 = Date()
        let target = await AppModel.otherFrontmostApp(within: 1)
        let found = target != nil && target?.processIdentifier != getpid()
        print("\(found ? "PASS" : "FAIL")  insert-again target: another app, found in \(Int(Date().timeIntervalSince(t17) * 1000)) ms")
        results.append(found)

        // Sol 0.5.0 #5: the login item plan (pure: nothing is registered here). A registration awaiting approval counts as
        // registered: off drops it, on at this path leaves it alone, from the old path it is moved; never registered twice.
        typealias Step = AppDelegate.LoginItemStep
        let new = "/Applications/JuniorOS Apps/Talk & Read.app", old = "/Applications/JuniorOS Apps/Talk and Read.app"
        let plans: [(String, Bool, SMAppService.Status, String?, [Step])] = [
            ("off, awaiting approval", false, .requiresApproval, new, [.unregister]),
            ("off, enabled", false, .enabled, new, [.unregister]),
            ("off, not registered", false, .notRegistered, nil, []),
            ("on, awaiting approval here", true, .requiresApproval, new, []),
            ("on, enabled here", true, .enabled, new, []),
            ("on, awaiting approval from the old path", true, .requiresApproval, old, [.unregister, .register, .record]),
            ("on, enabled from the old path", true, .enabled, old, [.unregister, .register, .record]),
            ("on, enabled, path unknown", true, .enabled, nil, [.unregister, .register, .record]),
            ("on, not registered", true, .notRegistered, new, [.register, .record]),
        ]
        let wrong = plans.filter { AppDelegate.loginItemSteps(on: $0.1, status: $0.2, recordedPath: $0.3, path: new) != $0.4 }.map(\.0)
        results.append(wrong.isEmpty)
        print("\(wrong.isEmpty ? "PASS" : "FAIL")  login item plans: \(plans.count) cases\(wrong.isEmpty ? "" : ", wrong: \(wrong)")")
        // 0.7.1: a copy dragged into Applications on any Mac registers; builds, test installs and translocated copies never.
        let places: [(String, Bool)] = [
            (new, true), ("/Applications/Talk & Read.app", true), ("/Users/someone/Applications/Talk & Read.app", true),
            ("/private/tmp/tr-test-install/Talk & Read.app", false), ("/Users/someone/Downloads/Talk & Read.app", false),
            ("/private/var/folders/x/AppTranslocation/ABC/d/Talk & Read.app", false), ("/Users/someone/src/.build/Talk & Read.app", false),
        ]
        let misplaced = places.filter { AppDelegate.isInstalledCopy($0.0, home: "/Users/someone") != $0.1 }.map(\.0)
        results.append(misplaced.isEmpty)
        print("\(misplaced.isEmpty ? "PASS" : "FAIL")  login item only from Applications: \(places.count) places\(misplaced.isEmpty ? "" : ", wrong: \(misplaced)")")

        // E3: with nothing reading or dictating, the model, engines and control server must sit still.
        let cpu0 = cpuSeconds(), t0 = Date()
        try? await Task.sleep(for: .seconds(20))
        let percent = (cpuSeconds() - cpu0) / Date().timeIntervalSince(t0) * 100
        results.append(percent < 0.5)
        print(String(format: "%@  idle CPU over 20 s: %.3f %% (limit 0.5 %%)", percent < 0.5 ? "PASS" : "FAIL", percent))

        let passed = results.filter { $0 }.count
        print("control self-test: \(passed)/\(results.count) passed")
        return passed == results.count ? 0 : 1
    }

    /// `mic` lists, chooses and refuses an unknown UID; `status` reports the choice. Nothing records.
    @MainActor private static func microphoneSteps(_ cli: URL, _ model: AppModel, _ results: inout [Bool]) async {
        func record(_ label: String, _ pass: Bool, _ detail: String) { results.append(pass); print("\(pass ? "PASS" : "FAIL")  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(detail)") }
        func choice(_ o: Outcome) -> String? { o.response?.data?["choice"]?.stringValue }
        func statusChoice() async -> String? {
            await call(cli, ["status"]).response?.data?["dictation"]?.objectValue?["microphone"]?.objectValue?["choice"]?.stringValue
        }
        let list = await call(cli, ["mic"])
        let inputs = list.response?.data?["inputs"]?.arrayValue ?? []
        record("mic lists the inputs", list.response?.ok == true && !inputs.isEmpty && choice(list) == "default", "\(inputs.count) inputs, choice \(choice(list) ?? "-")")
        if let uid = inputs.first?.objectValue?["uid"]?.stringValue {
            let set = await call(cli, ["mic", uid])
            let saved = model.settings.dictationMicrophone, status = await statusChoice()
            record("mic <uid> chooses it", set.response?.ok == true && choice(set) == uid && saved == uid && status == uid, "settings \(saved ?? "nil"), status \(status ?? "-")")
        } else {
            print("SKIP  mic <uid>: this Mac has no input device")
        }
        let before = model.settings.dictationMicrophone
        let unknown = await call(cli, ["mic", "no-such-device"])
        record("mic refuses an unknown UID", unknown.response?.code == "bad_args" && model.settings.dictationMicrophone == before, unknown.text)
        let reset = await call(cli, ["mic", "default"])
        let status = await statusChoice()
        record("mic default clears the choice", reset.response?.ok == true && model.settings.dictationMicrophone == nil && status == "default", "status \(status ?? "-")")
    }

    /// `history` is read-only, newest first, filterable and searchable, and changes nothing. Two reads are recorded first.
    @MainActor private static func historySteps(_ cli: URL, _ model: AppModel, _ results: inout [Bool]) async {
        func record(_ label: String, _ pass: Bool, _ detail: String) { results.append(pass); print("\(pass ? "PASS" : "FAIL")  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(detail)") }
        func entries(_ o: Outcome) -> [[String: JSONValue]] { (o.response?.data?["entries"]?.arrayValue ?? []).compactMap(\.objectValue) }
        model.recordOwnRead("History test: the first read, about gulls.")
        model.recordOwnRead("History test: the second read, about ferries.")
        let before = model.recentReads.count
        let all = await call(cli, ["history", "--kind", "read"])
        let texts = entries(all).compactMap { $0["text"]?.stringValue }
        let ours = entries(all).first
        record("history lists reads newest first", all.response?.ok == true && texts.first == "History test: the second read, about ferries."
               && texts.dropFirst().first == "History test: the first read, about gulls."
               && ours?["kind"]?.stringValue == "read" && ours?["app"]?.stringValue == ownAppName && ours?["date"]?.stringValue != nil,
               "\(texts.count) reads, first app \(ours?["app"]?.stringValue ?? "-")")
        let one = await call(cli, ["history", "--limit", "1", "--search", "GULLS"])
        record("history --search ignores case", entries(one).count == 1 && entries(one).first?["text"]?.stringValue?.contains("gulls") == true, one.text)
        let dictated = await call(cli, ["history", "--kind", "dictated", "--search", "History test"])
        record("history --kind dictated excludes reads", dictated.response?.ok == true && entries(dictated).isEmpty, "\(entries(dictated).count) entries")
        let none = await call(cli, ["history", "--search", "no such words anywhere"])
        record("history with no match is empty, not an error", none.response?.ok == true && entries(none).isEmpty
               && none.response?.data?["matching"]?.numberValue == 0, none.text)
        let badKind = await call(cli, ["history", "--kind", "listened"])
        let badLimit = await call(cli, ["history", "--limit", "501"])
        record("history refuses a bad kind and limit", badKind.status == 2 && badLimit.response?.code == "bad_args", "\(badKind.status) \(badLimit.response?.code ?? "-")")
        record("history changes nothing", model.recentReads.count == before, "\(model.recentReads.count) reads")
        let deleted = model.recentReads.first.map(\.id)
        if let deleted { model.deleteRead(deleted) }
        let afterDelete = await call(cli, ["history", "--kind", "read", "--search", "second read"])
        record("a deleted read is gone from history", deleted != nil && entries(afterDelete).isEmpty, "\(model.recentReads.count) reads")
        // history-delete: by the id `history` lists, only with --yes, and an unknown id is not_found.
        let listed = entries(await call(cli, ["history", "--kind", "read", "--search", "first read"])).first?["id"]?.stringValue ?? "-"
        let unconfirmed = await call(cli, ["history-delete", listed])
        let removed = await call(cli, ["history-delete", listed, "--yes"])
        let again = await call(cli, ["history-delete", listed, "--yes"])
        record("history-delete removes by id with --yes", unconfirmed.status == 2 && removed.response?.ok == true
               && !model.recentReads.contains { $0.id.uuidString == listed } && again.response?.code == "not_found",
               "\(unconfirmed.status) \(removed.text) \(again.response?.code ?? "-")")

        // Control characters encode as six bytes each (\u0001): a full history (200 reads) of 5,000 of them is about 6 MB on the
        // wire from 1 MB of text. The reply must stay inside its budget, say it was cut, and never fail as response_too_large.
        let heavy = String(repeating: "\u{1}", count: 5000)
        var ids: [UUID] = []
        for _ in 0..<model.settings.historyLimit { model.recordOwnRead(heavy); ids.append(model.recentReads[0].id) }
        let big = await call(cli, ["history", "--kind", "read", "--limit", "500"])
        let wire = big.text.utf8.count
        let cut = entries(big).count
        record("history stays inside its reply budget", big.response?.ok == true && wire <= AppModel.maxHistoryBytes + 4096
               && big.response?.data?["truncated"]?.boolValue == true && cut > 30 && cut < model.recentReads.count, "\(cut) of \(model.recentReads.count) entries, \(wire / 1024) KB")
        let few = await call(cli, ["history", "--kind", "read", "--limit", "10"])
        record("history within the budget is not cut", few.response?.ok == true && entries(few).count == 10 && few.response?.data?["truncated"]?.boolValue == false, "\(entries(few).count) entries")
        for id in ids { model.deleteRead(id) }
    }

    /// The Library through the CLI: list, open, read from the start, remove (refused under another caller's read and
    /// without --yes), paste and listen, and read again. Uses the sample.pdf `open` imported.
    @MainActor private static func librarySteps(_ cli: URL, _ model: AppModel, _ results: inout [Bool]) async {
        func record(_ label: String, _ pass: Bool, _ detail: String) { results.append(pass); print("\(pass ? "PASS" : "FAIL")  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(detail)") }
        guard let item = model.library.first else { return record("library steps", false, "the library is empty") }
        let id = item.id.uuidString
        let list = await call(cli, ["library"])
        let ids = (list.response?.data?["items"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
        record("library lists the imported PDF", list.response?.ok == true && ids.first == id, "\(ids.count) items")
        let shown = await call(cli, ["library-open", id])
        let words = shown.response?.data?["words"]?.numberValue ?? 0
        record("library-open shows it, with words", shown.response?.ok == true && words > 0 && WindowRouter.shared.libraryPath.last?.id == item.id,
               "\(Int(words)) words")
        let badFrom = await call(cli, ["library-open", id, "--read", "1", "--from", String(Int(words) + 5)])
        record("library-open refuses a word past the end", badFrom.response?.code == "bad_args", badFrom.text)
        let o1 = await call(cli, ["library-open", id, "--read", "1", "--from", "start", "--caller", "a"])
        results.append(check("a library-open --read 1 --from start", o1, .audio))
        let reading = await call(cli, ["status"]).response?.data?["reading"]?.objectValue?["item"]?.stringValue
        record("status names the item being read", reading == id, reading ?? "-")
        let unconfirmed = await call(cli, ["library-remove", id, "--caller", "b"])
        record("library-remove without --yes", unconfirmed.status == 2 && model.library.contains { $0.id == item.id }, "exit \(unconfirmed.status)")
        let o2 = await call(cli, ["library-remove", id, "--yes", "--caller", "b"])
        results.append(check("b library-remove while a reads it", o2, .busy))
        let o3 = await call(cli, ["stop", "--caller", "a"])
        results.append(check("a stop", o3, .ok))
        let removed = await call(cli, ["library-remove", id, "--yes", "--caller", "b"])
        let gone = !model.library.contains { $0.id == item.id }
            && !FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent(item.fileName).path)
        record("b library-remove after a stopped", removed.response?.ok == true && gone, removed.text)
        let missing = await call(cli, ["library-open", id])
        record("library-open of a removed item", missing.response?.code == "not_found", missing.text)

        let text = "Pasted for the control test, about the harbour."
        let o4 = await call(cli, ["read-pasted", text, "--caller", "a"])
        results.append(check("a read-pasted", o4, .audio))
        let pasted = model.library.first
        record("read-pasted keeps Library and History", pasted?.kind == "pasted" && pasted?.title == text && model.recentReads.first?.text == text
               && WindowRouter.shared.libraryPath.last?.id == pasted?.id && model.sessionInfo.item == pasted?.id
               && pasted.flatMap { try? model.documentText($0) } == text,
               pasted?.title ?? "-")
        let o5 = await call(cli, ["read-again", "--caller", "b"])
        results.append(check("b read-again while a reads", o5, .busy))
        let o6 = await call(cli, ["read-again", "--caller", "a"])
        results.append(check("a read-again (the latest read)", o6, .audio))
        let o7 = await call(cli, ["stop", "--caller", "a"])
        results.append(check("a stop", o7, .ok))
        if let pasted { model.remove(pasted) }
    }

    @MainActor private static func admissionSteps(_ cli: URL, _ model: AppModel, _ results: inout [Bool]) async {
        func record(_ label: String, _ pass: Bool) {
            results.append(pass)
            print("\(pass ? "PASS" : "FAIL")  \(label)")
        }
        let item = model.importText("A document for admission tests.", title: "Admission")
        let path = WindowRouter.shared.libraryPath
        let active = await call(cli, ["speak", "Keep reading while navigation is refused.", "--caller", "a"])
        record("navigation fixture is reading", active.response?.ok == true && model.liveSession != nil)
        let before = model.library.count
        for args in [["library-open", item.id.uuidString], ["library-open", item.id.uuidString, "--read", "1"],
                     ["open", "Tests/Fixtures/documents/sample.txt"], ["open", "Tests/Fixtures/documents/sample.txt", "--read", "1"],
                     ["open-url", "https://example.com"], ["open-url", "https://example.com", "--read", "1"]] {
            let result = await call(cli, args + ["--caller", "b"])
            record("navigation refuses another owner: \(args.joined(separator: " "))",
                   result.response?.code == "busy" && WindowRouter.shared.libraryPath == path && model.library.count == before)
        }
        model.stopSession()
        for read in ["1", "0"] {
            do {
                let data = try await model.openImported(ControlRequest(command: "open", args: ["read": read], caller: "a"), name: "test") {
                    await Task.yield()
                    _ = model.reserve("b")
                    return item
                }
                record("import keeps item without navigation (read \(read))", data["shown"] == .bool(false)
                       && data["id"] == .string(item.id.uuidString) && data["title"] == .string(item.title)
                       && data["kind"] == .string(item.kind) && data["notice"]?.stringValue?.contains("b is reading") == true
                       && model.owner?.caller == "b" && model.liveSession == nil && WindowRouter.shared.libraryPath == path)
            } catch { record("import keeps item without navigation (read \(read))", false) }
            model.stopSession()
        }

        let countWords = model.documentWordCount
        model.documentWordCount = { text in
            await Task.yield()
            model.remove(item)
            return TextKit.tokenize(text).count
        }
        let removed = await call(cli, ["library-open", item.id.uuidString, "--read", "1", "--caller", "a"])
        model.documentWordCount = countWords
        record("library-open rechecks removal after tokenisation", removed.response?.code == "not_found"
               && model.liveSession == nil && WindowRouter.shared.libraryPath == path)
        let removedImport = model.importText("Removed during import.", title: "Removed")
        do {
            _ = try await model.openImported(ControlRequest(command: "open", args: ["read": "1"], caller: "a"), name: "test") {
                await Task.yield()
                model.remove(removedImport)
                return removedImport
            }
            record("import rechecks removal after await", false)
        } catch let error as AppError {
            record("import rechecks removal after await", error.code == "not_found" && model.owner == nil && WindowRouter.shared.libraryPath == path)
        } catch { record("import rechecks removal after await", false) }

        let target = model.insertAgainTarget
        var release: CheckedContinuation<NSRunningApplication?, Never>?
        model.insertAgainTarget = { await withCheckedContinuation { release = $0 } }
        let insertion = Task { try await model.reinsertInOtherApp(UUID()) }
        let entered = await waitUntil(1) { release != nil }
        record("insert-again reserves before awaiting target", entered && model.insertingAgain)
        let second = await call(cli, ["insert-again", "--caller", "b"])
        let dictate = await call(cli, ["dictate-start", "--caller", "b"])
        record("concurrent insert-again is busy", second.response?.code == "busy")
        record("dictate-start during insert-again is busy", dictate.response?.code == "busy" && model.dictation.owner == nil)
        do {
            _ = try await model.reinsertInOtherApp(UUID())
            record("GUI shares insert-again guard", false)
        } catch let error as AppError { record("GUI shares insert-again guard", error.code == "busy") }
        catch { record("GUI shares insert-again guard", false) }
        release?.resume(returning: nil)
        _ = try? await insertion.value
        model.insertAgainTarget = target
        record("insert-again releases its guard", !model.insertingAgain)

        let saved = Paths.documents.appendingPathExtension("admission-backup")
        let historyCount = model.recentReads.count
        do {
            try FileManager.default.moveItem(at: Paths.documents, to: saved)
            defer {
                try? FileManager.default.removeItem(at: Paths.documents)
                try? FileManager.default.moveItem(at: saved, to: Paths.documents)
            }
            try Data().write(to: Paths.documents)   // a file blocks the directory even when running as root
            let failed = await call(cli, ["read-pasted", "Cannot persist this text.", "--caller", "a"])
            record("read-pasted reports persistence failure", failed.response?.code == "failed"
                   && failed.response?.message == "Could not open “Cannot persist this text.”"
                   && model.liveSession == nil && model.owner == nil && model.recentReads.count == historyCount
                   && WindowRouter.shared.libraryPath == path)
            if let failedItem = model.library.first { model.remove(failedItem) }
        } catch { record("read-pasted persistence fixture", false) }
        do {
            let text = "Home play still records and opens the saved text."
            let (homeItem, session) = try model.readPasted(text, id: model.reserve("user"))
            WindowRouter.shared.open(homeItem)
            record("Home play reads, records History and opens its item", model.session === session
                   && model.sessionInfo.item == homeItem.id && model.recentReads.count == historyCount + 1
                   && model.recentReads.first?.text == text && WindowRouter.shared.libraryPath.last?.id == homeItem.id
                   && (try? model.documentText(homeItem)) == text)
            model.stopSession()
            model.remove(homeItem)
        } catch { record("Home play reads, records History and opens its item", false) }
    }

    @MainActor private static func importReplaySteps(_ model: AppModel, _ results: inout [Bool]) async {
        let path = WindowRouter.shared.libraryPath
        let before = Set(model.library.map(\.id))
        let socket = Paths.dataRoot.appendingPathComponent("import-test.sock")
        do {
            let server = try ControlServer(path: socket) { r in
                await Task { @MainActor in
                    do {
                        let data = try await model.openImported(r, name: "test") {
                            let item = model.importText("Imported exactly once.", title: "Import retry")
                            await Task.yield()
                            _ = await model.handle(ControlRequest(command: "speak", args: ["text": "Another caller owns this read."], caller: "b", force: true))
                            return item
                        }
                        return ControlResponse(ok: true, data: data)
                    } catch let error as AppError {
                        return ControlResponse(ok: false, code: error.code, message: error.message)
                    } catch { return ControlResponse(ok: false, code: "failed", message: error.localizedDescription) }
                }.value
            }
            defer { server.stop() }
            let request = ControlRequest(id: UUID().uuidString, command: "open", args: ["read": "1"], caller: "a")
            let first = try await Task.detached { try ControlClient.send(request, to: socket, timeout: 5) }.value
            let retry = try await Task.detached { try ControlClient.send(request, to: socket, timeout: 5) }.value
            let added = model.library.filter { !before.contains($0.id) }
            var expected = first.data ?? [:]
            expected["replayed"] = .bool(true)
            let pass = first.ok && first.data?["shown"] == .bool(false) && first.data?["notice"] != nil
                && retry.ok && retry.data == expected && added.count == 1
                && first.data?["id"] == added.first.map { .string($0.id.uuidString) }
                && model.owner?.caller == "b" && model.liveSession != nil && WindowRouter.shared.libraryPath == path
            results.append(pass)
            print("\(pass ? "PASS" : "FAIL")  committed import replays once after another caller starts reading")
        } catch {
            results.append(false)
            print("FAIL  import replay: \(error)")
        }
        model.stopSession()
        for item in model.library where !before.contains(item.id) { model.remove(item) }
    }

    /// Vocabulary, pronunciations and shortcuts through the CLI: written where the Settings editors read them.
    @MainActor private static func wordListSteps(_ cli: URL, _ model: AppModel, _ results: inout [Bool]) async {
        func record(_ label: String, _ pass: Bool, _ detail: String) { results.append(pass); print("\(pass ? "PASS" : "FAIL")  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(detail)") }
        let revision = model.wordListsRevision
        let set = await call(cli, ["vocabulary-set", "marlow key", "Marlowe", "Quay"])
        let listed = await call(cli, ["vocabulary"])
        let rows = (listed.response?.data?["entries"]?.arrayValue ?? []).compactMap(\.objectValue)
        record("vocabulary-set then vocabulary", set.response?.ok == true && WordMapEditor.load(Paths.vocabulary)["marlow key"] == "Marlowe Quay"
               && rows.contains { $0["heard"]?.stringValue == "marlow key" && $0["typed"]?.stringValue == "Marlowe Quay" }
               && model.wordListsRevision > revision, listed.text)
        let removed = await call(cli, ["vocabulary-remove", "Marlow Key", "--yes"])
        let missing = await call(cli, ["vocabulary-remove", "marlow key", "--yes"])
        record("vocabulary-remove ignores case", removed.response?.ok == true && WordMapEditor.load(Paths.vocabulary)["marlow key"] == nil
               && missing.response?.code == "not_found", removed.text)
        let say = await call(cli, ["pronunciation-set", "Nguyen", "win"])
        let gone = await call(cli, ["pronunciation-remove", "Nguyen", "--yes"])
        record("pronunciation-set, pronunciation-remove", say.response?.ok == true && gone.response?.ok == true
               && WordMapEditor.load(Paths.pronunciations)["Nguyen"] == nil, gone.text)
        let suggestion = await call(cli, ["vocabulary-suggestion", "accept", "--heard", "nobody", "--typed", "Nobody"])
        record("vocabulary-suggestion of an unknown one", suggestion.response?.code == "not_found", suggestion.text)

        let correction = AutoLearn.Correction(heard: "okafor", typed: "Okafor")
        for _ in 0..<AutoLearn.threshold { model.dictation.learn([correction]) }
        do {
            let saved = try Data(contentsOf: Paths.vocabulary)
            try FileManager.default.removeItem(at: Paths.vocabulary)
            try FileManager.default.createDirectory(at: Paths.vocabulary, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: Paths.vocabulary)
                try? saved.write(to: Paths.vocabulary, options: .atomic)
            }
            let failed = await call(cli, ["vocabulary-suggestion", "accept", "--heard", correction.heard, "--typed", correction.typed])
            let listed = await call(cli, ["vocabulary"])
            let offers = listed.response?.data?["suggestions"]?.arrayValue ?? []
            record("suggestion save failure keeps suggestion", failed.response?.ok == false && failed.response?.code == "failed"
                   && model.dictation.suggestions.contains(correction)
                   && offers.contains { $0.objectValue?["heard"] == .string(correction.heard) }, failed.text)
        } catch { record("suggestion persistence failure fixture", false, "\(error)") }
        let accepted = await call(cli, ["vocabulary-suggestion", "accept", "--heard", correction.heard, "--typed", correction.typed])
        record("suggestion saved before dismissal", accepted.response?.ok == true
               && WordMapEditor.load(Paths.vocabulary)[correction.heard] == correction.typed
               && !model.dictation.suggestions.contains(correction), accepted.text)

        let bound = await call(cli, ["settings-set", "readShortcut", "ctrl+option+R"])
        let refused = await call(cli, ["settings-set", "readShortcut", "cmd+Q"])
        record("settings-set rebinds a shortcut", bound.response?.ok == true && model.settings.readShortcut.display == "⌃⌥R"
               && refused.response?.code == "bad_args", refused.text)
        let reset = await call(cli, ["shortcuts-reset", "--yes"])
        record("shortcuts-reset", reset.response?.ok == true && model.settings.readShortcut == TalkReadCore.Settings().readShortcut, reset.text)
    }

    private static func check(_ label: String, _ o: Outcome, _ expect: Expect) -> Bool {
        let r = o.response
        let pass: Bool
        switch expect {
        case .ok: pass = r?.ok == true
        case .audio: pass = r?.ok == true && r?.data?["firstAudioMs"]?.numberValue != nil
        case .busy: pass = r?.ok == false && r?.code == "busy"
        case .replayed: pass = r?.ok == true && r?.data?["replayed"]?.boolValue == true
        case .badArgs: pass = r?.ok == false && r?.code == "bad_args"
        case .unavailable: pass = r?.ok == false && r?.code == "unavailable"
        }
        let shown = o.text.count > 300 ? String(o.text.prefix(300)) + "…" : o.text
        print("\(pass ? "PASS" : "FAIL")  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(shown)")
        return pass
    }

    /// Runs the CLI off the main actor (the app's handler needs it) and decodes its `--json` reply.
    nonisolated private static func call(_ cli: URL, _ args: [String]) async -> Outcome {
        await Task.detached {
            let p = Process()
            p.executableURL = cli
            p.arguments = args + ["--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return Outcome(status: -1, response: nil, text: "\(error)") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Outcome(status: p.terminationStatus, response: try? JSONDecoder().decode(ControlResponse.self, from: data),
                           text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    @MainActor private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    private static func fixture() -> String? {
        let dir = URL(fileURLWithPath: "Tests/Fixtures/dictation")
        let wavs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return wavs.filter { $0.pathExtension == "wav" }.map(\.path).sorted().first
    }
}
