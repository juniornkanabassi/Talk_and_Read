// `TalkRead --selftest-control [clip.wav]`: drives the control handlers through the real socket and the real CLI.
// Headless (Junior, 21 Oct): no status item, windows or hotkeys, and reads use a silent engine, so nothing is heard.
import AppKit
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
    enum Expect { case ok, audio, busy, replayed, badArgs }
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
        await step("a open sample.pdf", ["open", docs.appendingPathComponent("sample.pdf").path, "--caller", "a"], .ok)
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

        // Sol #17: "Insert again" targets the app that comes forward once Talk and Read hides (never itself).
        let t17 = Date()
        let target = await AppModel.otherFrontmostApp(within: 1)
        let found = target != nil && target?.processIdentifier != getpid()
        print("\(found ? "PASS" : "FAIL")  insert-again target: another app, found in \(Int(Date().timeIntervalSince(t17) * 1000)) ms")
        results.append(found)

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

    private static func check(_ label: String, _ o: Outcome, _ expect: Expect) -> Bool {
        let r = o.response
        let pass: Bool
        switch expect {
        case .ok: pass = r?.ok == true
        case .audio: pass = r?.ok == true && r?.data?["firstAudioMs"]?.numberValue != nil
        case .busy: pass = r?.ok == false && r?.code == "busy"
        case .replayed: pass = r?.ok == true && r?.data?["replayed"]?.boolValue == true
        case .badArgs: pass = r?.ok == false && r?.code == "bad_args"
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
