// Headless self-tests (no windows, no live audio except the volume-0 R10 run).
// `--selftest-tts <file> [--voice id] [--rate x]`: synthesises every chunk with the neural engine, builds timings as
// ReadSession does, transcribes the audio with Parakeet and reports word-start error against the recogniser (R2); with
// `--rate`, renders through the production Player graph offline and checks WER and the media clock (revised R3).
// `--selftest-tts [<file>] --long`: 100k characters through a real ReadSession at volume 0 for 20 s (R10), plus the
// session's failure paths (device change while paused, output that will not start, out-of-range skips).
// 0.3.0 (V-A): `--voice qwen.<id> [--aligner <Parakeet v3 dir>]` is the timing run on Qwen3 in its own chunk sizes, judged
// against the acoustic onset check (English and French); `--voice qwen.<id> --long [--rate 2.5]` the 60 s sustained read
// with first audio, starvations, memory and GPU figures (V3, V7); `--fake-slow` drives slow and fast fake engines through
// real sessions and Players (fallback boundary, mid-chunk rate change, cancellation, unload); `--voice qwen.<id> --cancel`
// cancels Qwen3 chunks mid-generation and restarts at once (Sol inspection 4 #1, release build).
// 0.4.0 (B-A): the same runs take `--voice breeze.<id>` (Breeze TTS 2), the sustained run also hears the queued audio
// back and holds Breeze to its promised outcome per rate, `--cancel` cancels at every phase of a chunk (PLAN 0.4.0 Sol
// rev. 4, 8); `--switch` switches Qwen3 -> Breeze -> Qwen3 mid-chunk on the one MLX queue, leaves Breeze during warm-up,
// synthesis and cancellation through AppModel, and pauses through an idle unload (Sol rev. 1, 5).
import AVFoundation
import Darwin
import FluidAudio
import Foundation
import MLX
import ObjCExceptionCatch
import os
import TalkReadCore

enum SelfTest {
    static let outDir = URL(fileURLWithPath: "/private/tmp/talkread-selftest", isDirectory: true)

    /// Synthesises the text file, transcribes it back and reports timing error. Returns the process exit code.
    static func tts(file: String) async -> Int32 {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let path = file.hasPrefix("--") ? "Tests/Fixtures/reading.txt" : file
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("selftest-tts: cannot read \(path)")
            return 2
        }
        let voice = value("--voice") ?? Settings().voiceID
        let aligner = Aligner(directory: value("--aligner").map { URL(fileURLWithPath: $0, isDirectory: true) })
        let mlx = voice.hasPrefix("qwen.") || voice.hasPrefix("breeze.")
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            guard await helperChecks() else { return 1 }
            if args.contains("--fake-slow") { return try await fakeSlowRun(text) }
            if mlx, args.contains("--cancel") { return try await mlxCancelRun(text, voice: voice, aligner: aligner) }
            if args.contains("--switch") { return try await mlxSwitchRun(text, aligner: aligner) }
            if mlx, args.contains("--long") {
                return try await mlxLongRun(text, voice: voice, rate: value("--rate").flatMap(Float.init) ?? 2.5, aligner: aligner)
            }
            if args.contains("--long") { return try await longRun(text, voice: voice) }
            return try await timingRun(text, voice: voice, rate: value("--rate").flatMap(Float.init), aligner: aligner)
        } catch {
            print("selftest-tts: error \(error)")
            return 1
        }
    }

    // MARK: - R2 / R3

    @MainActor private static func timingRun(_ text: String, voice: String, rate: Float?, aligner: Aligner) async throws -> Int32 {
        let tokens = TextKit.tokenize(text)
        let slow = mlxEngine(voice, aligner)
        let language = (QwenEngine.references + BreezeEngine.references).first { $0.id == voice }?.language ?? (voice.hasPrefix("ff_") ? "fr" : "en")
        // Qwen3 and Breeze read in the session's bounded chunks: the opening chunk at 1x, then at most 160 characters.
        let chunks = slow != nil ? TextKit.chunks(text, tokens: tokens, firstMax: ReadSession.openingChars(rate: 1, kind: slow?.kind ?? .qwen), max: ReadSession.slowChars)
                                 : TextKit.chunks(text, tokens: tokens)
        // A Kokoro voice id (English, or French ff_*) runs the neural engine, qwen.* Qwen3, breeze.* Breeze, anything else
        // (an AVSpeechSynthesisVoice identifier) the system one.
        let engine: SpeechEngine = slow
            ?? (KokoroAneConstants.englishVoices.contains(voice) || voice.hasPrefix("ff_") ? NeuralEngine() as SpeechEngine : SystemEngine())
        var clock = Date()
        try await engine.prepare(voice: voice)
        print("model load + voice \(voice): \(ms(since: clock)) ms")

        var audio: [Float] = []
        var synths: [SynthChunk] = []
        var speakables: [String] = []
        var timings: [TalkReadCore.WordTiming] = []
        var spans: [(tokens: Range<Int>, start: Double, end: Double)] = []
        var synthSeconds = 0.0, firstChunkMs = 0
        for (k, chunk) in chunks.enumerated() {
            let speakable = Speakable.make(text, range: chunk.range, lexicon: [:], language: language)
            clock = Date()
            var s = try await engine.synthesize(speakable.text, voice: voice)
            synthSeconds += Date().timeIntervalSince(clock)
            if k == 0 { firstChunkMs = ms(since: clock) }
            if s.sampleRate != Player.sampleRate {   // system voices: 22.05 kHz, resampled as the Player does
                s = SynthChunk(samples: try AudioConverter(sampleRate: Player.sampleRate).resample(s.samples, from: s.sampleRate),
                               sampleRate: Player.sampleRate, words: s.words)
            }
            // Same arithmetic as ReadSession: offset = media start of the chunk, duration = its samples.
            let offset = Double(audio.count) / Player.sampleRate
            let duration = Double(s.samples.count) / s.sampleRate
            audio += s.samples
            synths.append(s)
            speakables.append(speakable.text)
            timings += Timeline.timings(chunkTokens: Array(tokens[chunk.tokens]), chunkTokenOffset: chunk.tokens.lowerBound,
                                        speakable: speakable, spoken: s.words, offset: offset, chunkDuration: duration, language: language)
            spans.append((chunk.tokens, offset, offset + duration))
        }
        let audioSeconds = Double(audio.count) / Player.sampleRate
        try writeWAV(audio, to: outDir.appendingPathComponent("tts.wav"))

        // Invariants: one timing per token in order, inside its chunk, no overlaps.
        var problems: [String] = []
        if timings.map(\.token) != Array(tokens.indices) { problems.append("timings do not cover tokens 0..<\(tokens.count) in order") }
        for span in spans {
            for w in timings where span.tokens.contains(w.token) {
                if w.start < span.start - 1e-6 || w.end > span.end + 1e-6 || w.end < w.start { problems.append("token \(w.token) [\(w.start), \(w.end)] outside chunk [\(span.start), \(span.end)]") }
            }
        }
        for (a, b) in zip(timings, timings.dropFirst()) where b.start < a.end - 1e-6 { problems.append("overlap at token \(b.token)") }
        let zeroLength = timings.filter { $0.end <= $0.start }
        print("zero-length sentinels (\(zeroLength.count)): \(zeroLength.map { tokens[$0.token].text }.joined(separator: " "))")

        // Recogniser round trip: Parakeet v2 for English, v3 (the aligner's copy) for French, where v2 is meaningless.
        let asr = try await Recogniser.load(v3: language == "fr" ? aligner.directory : nil)
        let heard = try await asr.transcribe(audio, language: language)
        let assign = Alignment.assign(spoken: heard.words.map(\.word), source: tokens.map(\.text), language: language)
        var asrStart: [Int: Double] = [:]
        for (i, j) in assign.enumerated() { if let j, asrStart[j] == nil { asrStart[j] = heard.words[i].start } }
        var signed: [Double] = []
        var tsv = "token\ttext\tstart\tend\tasr_start\terror_ms\n"
        for w in timings {
            let a = asrStart[w.token]
            if let a, w.end > w.start { signed.append(w.start - a) }
            tsv += "\(w.token)\t\(tokens[w.token].text)\t\(fmt(w.start))\t\(fmt(w.end))\t\(a.map(fmt) ?? "")\t\(a.map { String(Int(((w.start - $0) * 1000).rounded())) } ?? "")\n"
        }
        try tsv.write(to: outDir.appendingPathComponent("tts-words.tsv"), atomically: true, encoding: .utf8)
        let spoken = timings.filter { $0.end > $0.start }.count
        let absErr = signed.map(abs).sorted()
        let median = percentile(absErr, 0.5) * 1000, p90 = percentile(absErr, 0.9) * 1000
        let reference = speakables.joined(separator: " ")
        let wer1 = wer(reference: reference, hypothesis: heard.text, language: language)

        print("words: \(tokens.count) tokens, \(spoken) timed, \(signed.count) matched to the recogniser (\(pct(Double(signed.count) / Double(max(spoken, 1)))))")
        print("start error |ours - ASR|: median \(Int(median.rounded())) ms, p90 \(Int(p90.rounded())) ms; signed median \(Int((percentile(signed.sorted(), 0.5) * 1000).rounded())) ms (ours minus ASR)")
        let onset = onsetErrors(audio, starts: timings.filter { $0.end > $0.start }.map(\.start))
        print("acoustic check (no recogniser): \(onset.count) words after silence, ours - energy onset median \(Int((percentile(onset.sorted(), 0.5) * 1000).rounded())) ms, p90 |.| \(Int((percentile(onset.map(abs).sorted(), 0.9) * 1000).rounded())) ms")
        print("WER (ASR vs spoken text, 1x): \(pct(wer1))")
        print("first-chunk synthesis: \(firstChunkMs) ms; RTF \(String(format: "%.3f", synthSeconds / audioSeconds)) (\(fmt(synthSeconds)) s for \(fmt(audioSeconds)) s of audio, \(chunks.count) chunks)")
        print("invariants: \(problems.isEmpty ? "ok" : problems.prefix(10).joined(separator: "; "))")
        if let slow {
            let name = slow.kind == .breeze ? "Breeze" : "Qwen3"
            print("(\(name)'s words come from Parakeet v3, so the recogniser comparison above is not independent; the acoustic check decides)")
            return mlxVerdict(name, audio, timings: timings, firstChunkMs: firstChunkMs, synthSeconds: synthSeconds,
                              chunks: chunks.count, wer: wer1, invariants: problems.isEmpty) ? 0 : 1
        }
        var pass = problems.isEmpty && signed.count >= 200 && median <= 60 && p90 <= 150
        if language == "fr" {
            // PLAN 0.3.0 "Build results": Parakeet v3's French word starts run ~105 ms early, so French is judged by the
            // acoustic onset check instead of the recogniser.
            let onMedian = abs(percentile(onset.sorted(), 0.5) * 1000), onP90 = percentile(onset.map(abs).sorted(), 0.9) * 1000
            pass = problems.isEmpty && onset.count >= 100 && onMedian <= 60 && onP90 <= 150
            print("R2 (French, acoustic check decides): \(pass ? "PASS" : "FAIL") (|onset median| <= 60 ms, p90 <= 150 ms, >= 100 words after silence, invariants)")
        } else {
            print("R2: \(pass ? "PASS" : "FAIL") (median <= 60 ms, p90 <= 150 ms, >= 200 matched words, invariants)")
        }

        if let rate {
            // Revised R3 (PLAN.md): clock within 20 ms at every rate; WER <= 8 % up to 2x; above 2x, lower than Kokoro
            // speaking natively at that rate (the recogniser's own floor on fast speech).
            var clockOK = true
            for r in Set<Float>([0.5, 1, 1.5, 2, 2.5, 3, rate]).sorted() {   // offline burst trains: cheap, so every rate
                let c = try clockError(rate: r)
                clockOK = clockOK && c.maxAbs <= 0.020 && c.count >= 10
                print("clock vs rendered bursts at \(r)x (heard time): mean \(String(format: "%.1f", c.mean * 1000)) ms, max |err| \(String(format: "%.1f", c.maxAbs * 1000)) ms (\(c.count) bursts)")
            }
            // The production graph, all chunks queued back to back. The output is cut where the clock reaches each
            // chunk's media start (inside the pause between sentences) and each piece is transcribed on its own, so the
            // recogniser's 15 s window seams cannot drop words from 2.5x speech.
            let player = Player(manualRendering: true)
            player.rate = rate
            let starts = synths.map { player.enqueue($0) }
            player.play()
            let (rendered, readings) = try renderWithClock(player, seconds: audioSeconds / Double(rate) + 0.5)
            try writeWAV(rendered, to: outDir.appendingPathComponent("tts-\(rate)x.wav"))
            let cuts = starts.map { s in readings.first { $0.clock >= s }?.index ?? rendered.count } + [rendered.count]
            var hypothesis: [String] = []
            for k in synths.indices where cuts[k + 1] > cuts[k] {
                hypothesis.append((try? await asr.transcribe(Array(rendered[cuts[k] ..< cuts[k + 1]]), language: language).text) ?? "")
            }
            let werR = wer(reference: reference, hypothesis: hypothesis.joined(separator: " "), language: language)
            print("WER at \(rate)x through the Player graph: \(pct(werR)) (\(fmt(Double(rendered.count) / Player.sampleRate)) s rendered)")
            var werOK = werR <= 0.08, rule = "WER <= 8 %"
            if rate > 2, engine.kind == .neural, language == "en" {
                // Kokoro speaking natively at this rate, no time-pitch, same recogniser.
                let native = KokoroAneManager(variant: .english, defaultVoice: voice, version: .legacy)
                try await native.initialize()
                var heardNative: [String] = []
                for text in speakables {
                    let r = try await native.synthesizeDetailed(text: text, voice: voice, speed: rate)
                    heardNative.append((try? await asr.transcribe(r.samples, language: language).text) ?? "")
                }
                let werNative = wer(reference: reference, hypothesis: heardNative.joined(separator: " "))
                print("reference: Kokoro speaking natively at \(rate)x, same recogniser: WER \(pct(werNative))")
                werOK = werR < werNative
                rule = "WER \(pct(werR)) < native \(pct(werNative))"
            }   // ponytail: a system voice above 2x has no native reference, so it keeps the 8 % bar
            let ok = clockOK && werOK
            print("R3: \(ok ? "PASS" : "FAIL") (clock within 20 ms at 0.5-3x; \(rule))")
            pass = pass && ok
        }
        print("wrote \(outDir.path)/tts.wav, tts-words.tsv")
        return pass ? 0 : 1
    }

    /// Renders a train of 80 ms voiced bursts (200 Hz, five harmonics; the time-domain stretcher drops 5 ms clicks)
    /// through the production graph and compares where each burst comes out with what the clock said at that output
    /// sample. Errors are in heard (output) seconds, the 20 ms bar's unit: media-time error divided by the rate.
    /// Positive mean = clock ahead of the audio.
    @MainActor static func clockError(rate: Float) throws -> (mean: Double, maxAbs: Double, count: Int) {
        let sr = Player.sampleRate
        let times = stride(from: 0.5, through: 5.5, by: 0.5).map { $0 }
        var bursts = [Float](repeating: 0, count: Int(6 * sr))
        let n = Int(0.08 * sr), ramp = 48   // 2 ms raised-cosine edges
        for t in times {
            for j in 0 ..< n {
                let w = j < ramp ? 0.5 - 0.5 * cos(Double.pi * Double(j) / Double(ramp))
                    : j >= n - ramp ? 0.5 - 0.5 * cos(Double.pi * Double(n - j) / Double(ramp)) : 1
                bursts[Int(t * sr) + j] = Float(0.12 * w * (1 ... 5).reduce(0.0) { $0 + sin(2 * Double.pi * 200 * Double($1) * Double(j) / sr) })
            }
        }
        let player = Player(manualRendering: true)
        player.rate = rate
        player.enqueue(SynthChunk(samples: bursts, sampleRate: sr, words: []))
        player.play()
        let (out, readings) = try renderWithClock(player, seconds: 6 / Double(rate) + 0.3)
        var envelope: Float = 0
        let env = out.map { x -> Float in envelope = max(abs(x), envelope * 0.995); return envelope }   // peak hold bridges the 200 Hz zero crossings
        let peak = env.max() ?? 0
        var onsets: [Int] = []
        var i = 0
        while i < env.count {
            if env[i] > 0.2 * peak { onsets.append(i); i += Int(0.25 * sr / Double(rate)) } else { i += 1 }
        }
        guard onsets.count == times.count else { throw SpeechError.render("found \(onsets.count) bursts, expected \(times.count)") }
        let errors = zip(onsets, times).map { k, media -> Double in
            let r = readings.last { $0.index <= k }!
            return (r.clock + Double(k - r.index) / sr * Double(rate) - media) / Double(rate)
        }
        return (errors.reduce(0, +) / Double(errors.count), errors.map(abs).max() ?? 0, errors.count)
    }

    /// Renders in 10 ms blocks (about one realtime render cycle) and reads the clock after each block.
    @MainActor static func renderWithClock(_ player: Player, seconds: Double) throws -> (out: [Float], readings: [(index: Int, clock: Double)]) {
        var out: [Float] = []
        var readings: [(index: Int, clock: Double)] = []
        while Double(out.count) < seconds * Player.sampleRate {
            let blockStart = out.count
            out += try player.renderOffline(seconds: 0.01)
            readings.append((blockStart, player.currentTime))
        }
        return (out, readings)
    }

    // MARK: - R10

    @MainActor private static func longRun(_ fixture: String, voice: String) async throws -> Int32 {
        var text = fixture
        while text.utf16.count < 100_000 { text += "\n\n" + fixture }
        let engines = Engines()
        try await engines.neural.prepare(voice: voice)   // warm model, as for R1
        let v = Voice(id: voice, name: voice, accent: "", gender: "", engine: .neural, installed: true)
        let session = ReadSession(text: text, capture: nil, voice: v, rate: 1, startToken: 0, engines: engines, lexicon: [:])
        session.player.volume = 0
        session.start()
        var log: [String] = []
        var checks: [String: Bool] = [:]
        var held = 0, sentence = 0
        for second in 1 ... 20 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            switch second {
            case 8: session.setRate(2)
            case 12: session.seek(token: 1000)
            case 14: checks["seek lands on token 1000"] = (1000 ..< 1100).contains(session.currentToken ?? -1)
            case 15:
                session.pause(); held = session.currentToken ?? -1
                // Sol #8: the output device changes while paused (the engine's own notification; the player drops its queue).
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: session.player.engine)
            case 16:
                checks["pause holds the word"] = session.state == .paused && session.currentToken == held
                session.resume()
            case 17:
                checks["device change while paused: resume restarts at the held word"] = session.state == .playing
                    && (held ..< held + 60).contains(session.currentToken ?? -1) && session.player.queuedUntil > session.player.currentTime
                sentence = session.currentSentence ?? -1; session.skip(sentences: 1)
            case 18:
                checks["skip moves to the next sentence"] = session.currentSentence == sentence + 1
                if let system = await engines.system.voices().first { session.setVoice(system) }
            case 20: checks["system voice keeps reading"] = session.state == .playing && (session.currentSentence ?? 0) >= sentence + 1
            default: break
            }
            log.append("\(second)s:\(session.currentToken.map(String.init) ?? "-")")
        }
        // Sol #5: any Int is a valid skip (the CLI and socket pass it through); clamped, never overflowing. The session is
        // past sentence 0 here, so Int.max would have trapped.
        session.skip(sentences: .max)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        checks["skip(Int.max) goes to the last sentence"] = session.currentSentence == session.tokens.last?.sentence || session.state == .finished
        session.skip(sentences: .min)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        checks["skip(Int.min) goes to the first sentence"] = session.state == .playing && session.currentSentence == 0
        session.stop()
        // Sol #7: an output that will not start fails the read (AppModel releases ownership) instead of leaving it
        // "playing" with a frozen clock; no first-audio time is reported. Sol inspection 5 #1: the engine start and the
        // node's play each raise as AVFAudio does, never crashing the app.
        for step in [Player.Failure.start, .play] {
            let broken = ReadSession(text: fixture, capture: nil, voice: v, rate: 1, startToken: 0, engines: engines, lexicon: [:])
            broken.player.volume = 0
            broken.player.failNext = step
            broken.start()
            for _ in 0 ..< 50 where broken.state == .preparing { try await Task.sleep(nanoseconds: 100_000_000) }
            checks["output that will not start (\(step)) fails the read"] = { if case .failed = broken.state { return broken.firstAudioMs == nil && !broken.player.isPlaying } else { return false } }()
            broken.stop()
        }
        let first = session.firstAudioMs ?? .max
        let pass = session.player.starvations == 0 && first < 1000 && checks.values.allSatisfy { $0 }
        print("long text: \(text.utf16.count) characters, \(session.tokens.count) tokens")
        print("token each second (2x from 8 s, seek to 1000 at 12 s, pause 15-16 s with a device change, skip at 17 s, system voice from 18 s): \(log.joined(separator: " "))")
        print("session checks: \(checks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value ? "ok" : "FAILED")" }.joined(separator: "; "))")
        print("first audio \(first) ms; starvations \(session.player.starvations)")
        print("R10: \(pass ? "PASS" : "FAIL") (first audio < 1000 ms, starvations 0, session checks)")
        return pass ? 0 : 1
    }

    // MARK: - 0.3.0 engines (V-A)

    /// Qwen3 and Breeze: the MLX engines, each on a queue of its own here (the app shares one through `Engines`).
    private static func mlxEngine(_ voice: String, _ aligner: Aligner) -> SpeechEngine? {
        if voice.hasPrefix("qwen.") { return QwenEngine(aligner: aligner, queue: MLXQueue()) }
        if voice.hasPrefix("breeze.") { return BreezeEngine(aligner: aligner, queue: MLXQueue()) }
        return nil
    }

    /// Qwen3 or Breeze timing judged by the acoustic onset check, which is independent of Parakeet: median |ours - onset|
    /// <= 90 ms (PLAN 0.3.0 build results) and p90 <= 150 ms over at least 15 words that follow a silence, the invariants,
    /// and for Breeze (PLAN 0.4.0 Sol rev. 8) intelligibility: recogniser WER at 1x <= 8 %, R3's bar. Qwen3 keeps its
    /// 0.3.0 verdict; its WER is printed (French through Parakeet v3 has no bar).
    private static func mlxVerdict(_ name: String, _ audio: [Float], timings: [TalkReadCore.WordTiming], firstChunkMs: Int, synthSeconds: Double,
                                   chunks: Int, wer: Double, invariants: Bool) -> Bool {
        let onset = onsetErrors(audio, starts: timings.filter { $0.end > $0.start }.map(\.start))
        let absErr = onset.map(abs).sorted()
        let median = percentile(absErr, 0.5) * 1000, p90 = percentile(absErr, 0.9) * 1000
        print(String(format: "%@: first chunk %d ms; %.2fx real time including alignment (%d chunks)",
                     name, firstChunkMs, Double(audio.count) / Player.sampleRate / synthSeconds, chunks))
        let bias = percentile(onset.sorted(), 0.5), spread = onset.map { abs($0 - bias) }.sorted()
        print("\(name) acoustic check: \(onset.count) words after silence; |ours - onset| median \(Int(median.rounded())) ms, p90 \(Int(p90.rounded())) ms; signed median \(Int((bias * 1000).rounded())) ms (spread around it: median \(Int((percentile(spread, 0.5) * 1000).rounded())) ms, p90 \(Int((percentile(spread, 0.9) * 1000).rounded())) ms)")
        // PLAN 0.3.0 "Build results": Parakeet v3's 80 ms frames set the floor; 90 ms median is about 36 ms as heard at 2.5x.
        let breeze = name == "Breeze"
        let pass = invariants && onset.count >= 15 && median <= 90 && p90 <= 150 && (!breeze || wer <= 0.08)
        print("\(name) timing: \(pass ? "PASS" : "FAIL") (acoustic median <= 90 ms, p90 <= 150 ms, >= 15 words after silence, \(breeze ? "WER <= 8 %, " : "")invariants)")
        return pass
    }

    /// A sustained Qwen3 or Breeze read through a real session and Player at volume 0 (V3, V7): the model is loaded
    /// first, as on selection; then 60 s at `rate` with the Kokoro fallback warm. Passes with no starvation, no duplicated
    /// or skipped token, a clean hand-over if any, the queued audio heard back (`queuedSpeech`), and the outcome the
    /// rate promises: Qwen3 first audio <= 2.5 s, kept up or handed over (PLAN 0.3.0); Breeze up to
    /// `BreezeEngine.keepsUpTo` with no fallback, first audio recorded (PLAN 0.4.0 Sol rev. 8: the 2x of the plan was
    /// not reached, so the measured speed is promised); above it Breeze is not loaded and the read starts on Kokoro with
    /// the reason and Kokoro's first audio, under R10's 1000 ms (lead, 0.4.0).
    @MainActor private static func mlxLongRun(_ fixture: String, voice: String, rate: Float, aligner: Aligner) async throws -> Int32 {
        var text = fixture
        while text.utf16.count < 20_000 { text += "\n\n" + fixture }
        let breeze = voice.hasPrefix("breeze."), name = breeze ? "Breeze" : "Qwen3"
        let above = breeze && rate > BreezeEngine.keepsUpTo
        let queue = MLXQueue(), log = ChunkLog()
        let slow = LoggingEngine(breeze ? BreezeEngine(aligner: aligner, queue: queue) : QwenEngine(aligner: aligner, queue: queue) as SpeechEngine, log)
        let engines = Engines(neural: LoggingEngine(NeuralEngine(), log), qwen: breeze ? nil : slow, breeze: breeze ? slow : nil, aligner: aligner, mlx: queue)
        guard let v = await slow.voices().first(where: { $0.id == voice }), v.installed else {
            print("\(name) or the aligner is not installed (model folder \((breeze ? BreezeEngine.folder : QwenEngine.folder).path), aligner \(aligner.directory.path))")
            return 1
        }
        let before = footprint()
        var clock = Date()
        let fallbackID = v.language == "fr" ? "ff_siwis" : "af_heart"
        if above {   // as AppModel.warm on selection: Kokoro, not the model
            try await engines.neural.prepare(voice: fallbackID)
            print("\(name) not loaded above its \(BreezeEngine.keepsUpTo)x; Kokoro warmed in \(ms(since: clock)) ms")
        } else {
            try await slow.prepare(voice: voice)
            print(String(format: "%@ load + voice + warm-up: %d ms; footprint %.0f MB before, %.0f MB loaded (MLX active %.0f MB, cache %.0f MB)",
                         name, ms(since: clock), before, footprint(), Double(Memory.activeMemory) / 1e6, Double(Memory.cacheMemory) / 1e6))
        }
        let fallback = Voice(id: fallbackID, name: fallbackID, accent: "", gender: "Female", engine: .neural, installed: true, language: v.language)
        // As the app does at launch: the first audio engine start in a process costs ~0.3 s (measured 1.65 s first audio
        // without this, 1.35 s with it). The read warms its Kokoro fallback itself.
        Player.warmOutput()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let session = ReadSession(text: text, capture: nil, voice: v, rate: rate, startToken: 0, engines: engines, lexicon: [:], fallback: fallback)
        session.player.volume = 0
        clock = Date()
        session.start()
        var peak = 0.0, gpu: [Int] = [], switched: Int?, log5: [String] = [], starved: [Int] = []
        for second in 1 ... 60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            peak = max(peak, footprint())
            if let u = await Task.detached(operation: { gpuUtilisation() }).value { gpu.append(u) }
            if switched == nil, session.fallbackReason != nil { switched = second }
            if session.player.starvations > starved.count { starved.append(second) }
            if second % 5 == 0 { log5.append("\(second)s:\(session.currentToken.map(String.init) ?? "-")") }
        }
        let playing = session.state == .playing
        let tokens = session.timings.map(\.token)
        let consecutive = tokens == Array(0 ..< tokens.count)
        let made = session.made
        let byModel = made.filter { $0.voice == voice }, byFallback = made.filter { $0.voice != voice }
        let clean = made.map(\.voice).drop { $0 == voice }.allSatisfy { $0 == fallbackID }
        session.stop()
        engines.unloadAll()
        while engines.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = footprint()
        let first = session.firstAudioMs ?? .max
        let starvations = session.player.starvations
        print("sustained read at \(rate)x: \(text.utf16.count) characters, \(made.count) chunks queued in 60 s (\(byModel.count) \(name), \(byFallback.count) fallback)")
        print("\(name) chunk sizes (tokens): \(byModel.map { "\($0.tokens.count)" }.joined(separator: " "))")
        print("token every 5 s: \(log5.joined(separator: " "))")
        print("fallback: \(session.fallbackReason.map { "\"\($0)\" after \(switched ?? 0) s, at token \(byFallback.first?.tokens.lowerBound ?? -1)" } ?? "none, \(name) kept up")")
        print("first audio \(first) ms; starvations \(starvations)\(starved.isEmpty ? "" : " (by \(starved.map { "\($0) s" }.joined(separator: ", ")))"); tokens queued \(tokens.count), consecutive from 0: \(consecutive); clean hand-over: \(clean)")
        let sortedGPU = gpu.sorted()
        print(String(format: "memory (phys footprint): %.0f MB before load, peak %.0f MB while reading, %.0f MB after unload", before, peak, after))
        if !gpu.isEmpty { print("GPU utilisation while reading: median \(sortedGPU[sortedGPU.count / 2]) %, mean \(gpu.reduce(0, +) / gpu.count) % (\(gpu.count) samples)") }
        // How fast the model really rendered during this run: other apps on the GPU (a video playing) slow Breeze a lot.
        let own = log.entries.filter { $0.voice == voice && !$0.samples.isEmpty }
        print(String(format: "%@ rendered %.2fx real time over its %d chunks, alignment included (a quiet M3 Max: Breeze about 2.2x)", name,
                     own.reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate } / max(own.reduce(0) { $0 + $1.work }, 0.001), own.count))
        let heard = try await queuedSpeech(made: made, log: log, language: v.language, aligner: aligner)
        let outcome = above ? made.allSatisfy { $0.voice == fallbackID } && session.fallbackReason != nil && first < 1000
            : breeze ? switched == nil : first <= 2500
        let rule = above ? "started on Kokoro with the reason, first audio < 1000 ms"
            : breeze ? "no fallback at \(rate)x, first audio recorded" : "first audio <= 2500 ms, clean or no fallback"
        let pass = playing && starvations == 0 && consecutive && clean && heard && outcome
        print("\(name) sustained: \(pass ? "PASS" : "FAIL") (\(rule), starvations 0, consecutive tokens, queued speech heard back, still playing at 60 s)")
        return pass ? 0 : 1
    }

    /// Sol rev. 8: the chunks a session queued, each as its engine returned it (what the Player got), transcribed one by
    /// one and compared with what each was asked to say: WER <= 8 % (R3's bar) and no run of 4 or more words missing or
    /// added, which a sentence dropped or said twice inside the audio would leave. With the caller's check that the
    /// queued chunks cover the tokens once, in order, that is the text read once (a chunk queued twice or skipped at a
    /// hand-over fails there).
    @MainActor private static func queuedSpeech(made: [(tokens: Range<Int>, voice: String)], log: ChunkLog, language: String, aligner: Aligner) async throws -> Bool {
        let entries = Array(log.entries.prefix(made.count))   // a chunk finished after the read stopped was never queued
        guard entries.map(\.voice) == made.map(\.voice), made.first?.tokens.lowerBound == 0, let end = made.last?.tokens.upperBound else {
            print("queued speech: the recorded chunks do not match the queued ones (\(entries.count) recorded, \(made.count) queued): FAILED")
            return false
        }
        let asr = try await Recogniser.load(v3: language == "fr" ? aligner.directory : nil)
        var heard: [String] = []
        for e in entries where !e.samples.isEmpty {
            let samples = e.sampleRate == Player.sampleRate ? e.samples : try AudioConverter(sampleRate: Player.sampleRate).resample(e.samples, from: e.sampleRate)
            for piece in pauses(samples) { heard.append(try await asr.transcribe(piece, language: language).text) }
        }
        let d = wordDiff(reference: entries.map(\.text).joined(separator: " "), hypothesis: heard.joined(separator: " "), language: language)
        let ok = d.wer <= 0.08 && d.missing < 4 && d.extra < 4
        print("queued speech heard back (\(entries.count) chunks, tokens 0..<\(end)): WER \(pct(d.wer)); longest run of words missing \(d.missing), added \(d.extra) (\(d.worst)): \(ok ? "ok" : "FAILED")")
        return ok
    }

    /// Pieces of at most 12 s, each over-long one cut at the quietest 10 ms of its middle third (a pause between words),
    /// so the recogniser's own 15 s windows never seam inside a chunk (a seam dropped a whole sentence, 23 Oct).
    private static func pauses(_ x: [Float]) -> [[Float]] {
        guard Double(x.count) / Player.sampleRate > 12 else { return [x] }
        let hop = Int(Player.sampleRate / 100)
        func energy(_ i: Int) -> Float { x[i * hop ..< (i + 1) * hop].reduce(0) { $0 + $1 * $1 } }
        let cut = (x.count / 3 / hop ..< 2 * x.count / 3 / hop).min { energy($0) < energy($1) }! * hop
        return pauses(Array(x[..<cut])) + pauses(Array(x[cut...]))
    }

    /// Sol inspection 4 #1 and Sol plan review 0.4.0 #4: a Qwen3 or Breeze chunk cancelled anywhere (from the moment its
    /// generation starts: Breeze's reference encoding, then prefill, then decoding; and while it is being aligned) gives
    /// no result, keeps the queue busy until the dependency's generation has really ended, and never overlaps the next
    /// chunk's generation (`MLXQueue.generations`); so does a cancelled cold load. Reports the worst cancel-to-free drain
    /// and how much a warm Kokoro chunk slows when it runs during a drain (the watchdog starts the fallback at once).
    @MainActor private static func mlxCancelRun(_ text: String, voice: String, aligner: Aligner) async throws -> Int32 {
        guard let engine = mlxEngine(voice, aligner), await engine.voices().first(where: { $0.id == voice })?.installed == true else {
            print("\(voice): the model or the aligner is not installed"); return 1
        }
        let name = engine.kind == .breeze ? "Breeze" : "Qwen3"
        func now() -> Int { MLXQueue.generations.withLock { $0.now } }
        var pass = true
        func check(_ what: String, _ ok: Bool) { print("\(ok ? "ok" : "FAILED"): \(what)"); pass = pass && ok }
        func cancelled<T>(_ t: Task<T, Error>) async -> Bool { do { _ = try await t.value; return false } catch { return error is CancellationError } }

        // A cold load cancelled a second in: no result, busy until the load has stopped, and the next prepare loads afresh.
        var clock = Date()
        let load = Task { try await engine.prepare(voice: voice) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var cancelAt = Date()
        load.cancel()
        let loadCancelled = await cancelled(load)
        let loadDrain = Date().timeIntervalSince(cancelAt)
        check(String(format: "cancel a cold load 1 s in: no result %@, engine free %.2f s after the cancel", loadCancelled ? "yes" : "no", loadDrain),
              loadCancelled && !engine.isBusy && now() == 0)
        clock = Date()
        try await engine.prepare(voice: voice)
        print("load + warm-up after that: \(ms(since: clock)) ms")

        let chunk = String(text.prefix(300)), next = "And here is the next chunk."
        clock = Date()
        let whole = try await engine.synthesize(chunk, voice: voice)
        let wholeSeconds = Date().timeIntervalSince(clock)
        print(String(format: "an uncancelled %d-character chunk: %.2f s of audio in %.2f s", chunk.utf16.count, Double(whole.samples.count) / whole.sampleRate, wholeSeconds))

        // Where in the chunk each round cancels: seconds after its generation starts, or (nil) once generation has ended
        // and the chunk is being aligned. 0-150 ms span Breeze's reference encoding and prefill (measured with `.info`).
        let points: [(String, Double?)] = [("at generation start", 0), ("10 ms in", 0.01), ("25 ms in", 0.025), ("50 ms in", 0.05),
                                           ("100 ms in", 0.1), ("150 ms in", 0.15), ("decoding, 0.5 s in", 0.5), ("during alignment", nil)]
        var worst = 0.0
        for (round, (label, offset)) in points.enumerated() {
            MLXQueue.generations.withLock { $0.peak = $0.now }
            let first = Task { try await engine.synthesize(chunk, voice: voice) }
            while now() == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            if let offset {
                if offset > 0 { try await Task.sleep(nanoseconds: UInt64(offset * 1e9)) }
            } else {
                while now() > 0 { try await Task.sleep(nanoseconds: 1_000_000) }   // generated; the aligner runs now
            }
            cancelAt = Date()
            first.cancel()
            if round == 0 {
                // Spins off the main actor (a gap may last a millisecond): `isBusy` read before the count, so a running
                // generation seen after an idle engine really ran while the engine said idle.
                let watch = Task.detached { () -> Bool in
                    var idle = false
                    while true {
                        let busy = engine.isBusy
                        if MLXQueue.generations.withLock({ $0.now }) == 0 { return idle }
                        if !busy { idle = true }
                    }
                }
                let idle = await watch.value
                let none = await cancelled(first)
                let drain = Date().timeIntervalSince(cancelAt)
                worst = max(worst, drain)
                check(String(format: "cancel alone %@: no result %@, engine free %.0f ms after the cancel, busy until generation ended: %@",
                             label, none ? "yes" : "no", drain * 1000, idle ? "no" : "yes"), none && !idle)
            } else {
                let restart = Task { try await engine.synthesize(next, voice: voice) }
                let none = await cancelled(first)
                let drain = Date().timeIntervalSince(cancelAt)
                worst = max(worst, drain)
                let r = try await restart.value
                let peak = MLXQueue.generations.withLock { $0.peak }
                // 0.3.0's bar: a chunk cancelled while it decodes frees the engine within 300 ms (a decode step).
                check(String(format: "cancel %@ and restart: no result %@, freed in %.0f ms, at most %d generation(s) at once, next chunk %.2f s of audio ready %.0f ms after the cancel",
                             label, none ? "yes" : "no", drain * 1000, peak, Double(r.samples.count) / r.sampleRate, Date().timeIntervalSince(cancelAt) * 1000),
                      none && peak == 1 && !r.samples.isEmpty && (offset != 0.5 || drain <= 0.3))
            }
            while engine.isBusy || now() > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        print(String(format: "worst cancel-to-free drain of a chunk: %.0f ms", worst * 1000))

        // The watchdog starts the warm Kokoro fallback the moment it abandons a chunk, while that chunk drains.
        let kokoro = NeuralEngine(), line = "The clerk smiled and noted that the average repair time was eighteen months."
        try await kokoro.prepare(voice: "af_heart")
        var alone: [Double] = [], during: [Double] = []
        for _ in 0 ..< 3 {
            clock = Date(); _ = try await kokoro.synthesize(line, voice: "af_heart"); alone.append(Date().timeIntervalSince(clock))
        }
        for offset in [0.0, 0.05, 0.5, 0.5] {
            let first = Task { try await engine.synthesize(chunk, voice: voice) }
            while now() == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            if offset > 0 { try await Task.sleep(nanoseconds: UInt64(offset * 1e9)) }
            first.cancel()
            clock = Date(); _ = try await kokoro.synthesize(line, voice: "af_heart"); during.append(Date().timeIntervalSince(clock))
            _ = await cancelled(first)
            while engine.isBusy || now() > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        print(String(format: "warm Kokoro chunk (%d characters): alone %@ ms; started at a %@ cancel %@ ms; slowed by at most %.0f ms", line.utf16.count,
                     alone.map { String(Int($0 * 1000)) }.joined(separator: "/"), name, during.map { String(Int($0 * 1000)) }.joined(separator: "/"),
                     max(0, (during.max() ?? 0) - (alone.max() ?? 0)) * 1000))
        print("\(name) cancel/restart: \(pass ? "PASS" : "FAIL") (no result after a cancel, never two generations at once, busy until generation ended, freed within 300 ms while decoding)")
        return pass ? 0 : 1
    }

    /// Sol plan review 0.4.0 #1 and #5, on one shared queue as in the app. (1) Reads switch Qwen3 -> Breeze -> Qwen3, each
    /// stopped with a chunk in flight and the next started at once: never two generations at once, each read starts in its
    /// own voice (the aligner traps if used off the queue). (2) Leaving Breeze while it warms up, while it synthesises and
    /// while a cancelled chunk drains (AppModel's own switch path) unloads it within 0.5 s of the queue going idle, not at
    /// the idle timer. (3) Pause, an idle unload, resume: the read goes on, every token once, no starvation.
    @MainActor private static func mlxSwitchRun(_ fixture: String, aligner: Aligner) async throws -> Int32 {
        var checks: [(String, Bool)] = []
        func check(_ what: String, _ ok: Bool) { checks.append((what, ok)); print("\(ok ? "ok" : "FAILED"): \(what)") }
        func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !condition() { if Date() >= end { return false }; try? await Task.sleep(nanoseconds: 5_000_000) }
            return true
        }
        func gens() -> Int { MLXQueue.generations.withLock { $0.now } }
        let kokoro = Voice(id: "af_heart", name: "af_heart", accent: "", gender: "Female", engine: .neural, installed: true)
        var engines = Engines(aligner: aligner)
        let voices = await engines.allVoices()
        guard ["qwen.us_warm", "breeze.us_warm"].allSatisfy({ id in voices.contains { $0.id == id && $0.installed } }) else {
            print("Qwen3, Breeze or the aligner is not installed"); return 1
        }
        func voice(_ id: String) -> Voice { voices.first { $0.id == id }! }
        Player.warmOutput()

        // (1)
        MLXQueue.generations.withLock { $0.peak = $0.now }
        for id in ["qwen.us_warm", "breeze.us_warm", "qwen.us_warm"] {
            // At 1x the producer runs ahead, so the model is nearly always generating when the read is stopped.
            let s = ReadSession(text: fixture, capture: nil, voice: voice(id), rate: 1, startToken: 0, engines: engines, lexicon: [:], fallback: kokoro)
            s.player.volume = 0
            let started = Date()
            s.start()
            let playing = await until(60) { s.state == .playing }
            let inFlight = await until(20) { gens() > 0 }
            s.stop()
            check(String(format: "%@ read playing after %.1f s, stopped with a chunk in flight: %@", id, s.firstAudioMs.map { Double($0) / 1000 } ?? Date().timeIntervalSince(started),
                         inFlight ? "yes" : "no"), playing && inFlight && s.made.first?.voice == id)
        }
        _ = await until(30) { !engines.isBusy }
        check("Qwen3 -> Breeze -> Qwen3: at most \(MLXQueue.generations.withLock { $0.peak }) generation(s) at once", MLXQueue.generations.withLock { $0.peak } == 1)
        engines.unloadAll()
        _ = await until(30) { !engines.isBusy }

        // (2) Through AppModel with real engines: picking Breeze loads it; leaving it must free it promptly.
        let model = AppModel.shared
        model.engines = Engines(aligner: aligner)
        engines = model.engines
        await model.loadVoices()
        model.settings.voiceID = "af_heart"
        let breeze = engines.breeze, line = String(fixture.prefix(300))
        for phase in ["warm-up", "synthesis", "cancellation"] {
            model.settings.voiceID = "breeze.us_warm"   // the app loads it ahead of the read
            _ = await until(5) { engines.isBusy }
            var work: Task<SynthChunk, Error>?
            if phase == "warm-up" {
                try await Task.sleep(nanoseconds: 1_000_000_000)   // inside the load
            } else {
                _ = await until(120) { !engines.isBusy }
                work = Task { try await breeze.synthesize(line, voice: "breeze.us_warm") }
                _ = await until(10) { gens() > 0 }
                try await Task.sleep(nanoseconds: 500_000_000)
                if phase == "cancellation" { work?.cancel() }
            }
            let unloads = engines.unloads, switchedAt = Date()
            let idle = OSAllocatedUnfairLock<Date?>(initialState: nil)
            model.settings.voiceID = "af_heart"   // leave Breeze while its queue is busy
            let busy = engines.isBusy
            engines.whenIdle { idle.withLock { $0 = $0 ?? Date() } }
            let unloaded = await until(120) { engines.unloads > unloads }
            let unloadedAt = Date()
            _ = await until(30) { !engines.isBusy }
            _ = try? await work?.value
            let lag = idle.withLock { $0 }.map { unloadedAt.timeIntervalSince($0) } ?? .infinity
            check(String(format: "leave Breeze during %@: queue busy at the switch %@, unloaded %.2f s after the switch, %.0f ms after the queue went idle",
                         phase, busy ? "yes" : "no", unloadedAt.timeIntervalSince(switchedAt), lag * 1000), busy && unloaded && lag <= 0.5)
        }

        // (3)
        engines = Engines(aligner: aligner)
        try await engines.breeze.prepare(voice: "breeze.us_warm")
        let s = ReadSession(text: fixture + "\n\n" + fixture, capture: nil, voice: voice("breeze.us_warm"), rate: BreezeEngine.keepsUpTo, startToken: 0,
                            engines: engines, lexicon: [:], fallback: kokoro)
        s.player.volume = 0
        s.start()
        _ = await until(30) { s.state == .playing }
        try await Task.sleep(nanoseconds: 8_000_000_000)
        s.pause()
        let pausedAt = s.made.count
        engines.unloadAll()   // what the idle timer does to a paused read (PLAN 0.3.0 rev. 5)
        _ = await until(60) { !engines.isBusy }
        s.resume()
        try await Task.sleep(nanoseconds: 15_000_000_000)
        let after = s.made.dropFirst(pausedAt).map(\.voice)
        let whole = s.timings.map(\.token) == Array(0 ..< s.timings.count)
        check("pause, idle unload, resume: playing \(s.state == .playing), starvations \(s.player.starvations), tokens consecutive \(whole), chunks after resume "
              + "\(after.filter { $0 == "breeze.us_warm" }.count) Breeze (reloaded) and \(after.filter { $0 == "af_heart" }.count) Kokoro\(s.fallbackReason.map { " (\($0))" } ?? "")",
              (s.state == .playing || s.state == .finished) && s.player.starvations == 0 && whole && !after.isEmpty)
        s.stop()
        engines.unloadAll()
        _ = await until(30) { !engines.isBusy }

        let pass = checks.allSatisfy(\.1)
        print("switch checks: \(checks.filter(\.1).count)/\(checks.count) passed")
        print("Qwen3/Breeze switching: \(pass ? "PASS" : "FAIL") (one generation at a time across engines, prompt unload after leaving Breeze, pause/unload/resume)")
        return pass ? 0 : 1
    }

    /// Slow and fast fake engines through real sessions and Players at volume 0 (PLAN 0.3.0 Sol revision 10): the budget
    /// hand-over at 2.5x, the watchdog after a 1x -> 3x change in mid-chunk, a slow engine that keeps up at 2.5x, then
    /// cancellation, busy and unload, a fallback left cold by an idle unload, French system fallbacks. Every finished read
    /// must have every token once, in order, and no starvation.
    @MainActor private static func fakeSlowRun(_ fixture: String) async throws -> Int32 {
        var checks: [(String, Bool)] = []
        func check(_ what: String, _ ok: Bool) { checks.append((what, ok)); if !ok { print("FAILED: \(what)") } }
        let slowVoice = Voice(id: "fake.slow", name: "Fake slow", accent: "", gender: "Female", engine: .qwen, installed: true)
        let fastVoice = Voice(id: "fake.fast", name: "Fake Kokoro", accent: "", gender: "Female", engine: .neural, installed: true)
        let ns = fixture as NSString
        func excerpt(_ chars: Int) -> String {   // whole sentences, about `chars` long
            let end = ns.range(of: ". ", options: .backwards, range: NSRange(location: 0, length: min(chars, ns.length))).location
            return ns.substring(to: end == NSNotFound ? min(chars, ns.length) : end + 1)
        }
        func until(_ timeout: Double, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        /// One read with fresh fakes; `during` runs while it plays. Returns the session and the slow fake.
        func read(_ text: String, rate: Float, slowRTF: Double, timeout: Double = 40, engines given: Engines? = nil, voice: Voice = slowVoice,
                  fallback: Voice? = fastVoice, during: (ReadSession, FakeEngine) async -> Void = { _, _ in }) async -> (ReadSession, FakeEngine, Engines) {
            let engines = given ?? Engines(neural: FakeEngine(kind: .neural, realTime: 60), system: SystemEngine(),
                                           qwen: FakeEngine(kind: .qwen, realTime: slowRTF))
            let slow = engines.qwen as! FakeEngine
            let s = ReadSession(text: text, capture: nil, voice: voice, rate: rate, startToken: 0, engines: engines, lexicon: [:], fallback: fallback)
            s.player.volume = 0
            s.start()
            await during(s, slow)
            await until(timeout) { s.state == .finished }
            return (s, slow, engines)
        }
        func whole(_ s: ReadSession) -> Bool { s.state == .finished && s.timings.map(\.token) == Array(s.tokens.indices) }
        func handover(_ s: ReadSession) -> Bool {   // slow chunks, then fallback chunks only, contiguous
            let v = s.made.map(\.voice)
            return v.drop { $0 == slowVoice.id }.allSatisfy { $0 == fastVoice.id } && zip(s.made, s.made.dropFirst()).allSatisfy { $0.tokens.upperBound == $1.tokens.lowerBound }
        }
        func describe(_ name: String, _ s: ReadSession, _ slow: FakeEngine) {
            print("\(name): first audio \(s.firstAudioMs ?? -1) ms; chunks (tokens/voice) \(s.made.map { "\($0.tokens.count)\($0.voice == slowVoice.id ? "s" : "k")" }.joined(separator: " ")); starvations \(s.player.starvations); reason \(s.fallbackReason ?? "-"); slow calls \(slow.calls), cancelled \(slow.cancelled)")
        }

        // 1. The budget hands over before a chunk that cannot be ready: a 1.5x real-time engine at 2.5x playback.
        var (s, slow, _) = await read(excerpt(450), rate: 2.5, slowRTF: 1.5)
        describe("1 budget at 2.5x", s, slow)
        check("1: read finished, every token once in order", whole(s))
        check("1: switched with the 2.5x message", s.fallbackReason == "Switched to Kokoro to keep up at 2.5×" && s.effectiveVoice == fastVoice && s.voice == slowVoice)
        check("1: slow chunks then fallback chunks, contiguous", handover(s) && s.made.first?.voice == slowVoice.id)
        check("1: nothing abandoned (decided before the chunk)", slow.cancelled == 0)
        check("1: no starvation", s.player.starvations == 0)

        // 2. The watchdog abandons a chunk in flight when the rate rises from 1x to 3x mid-chunk; the same chunk is remade.
        var engines: Engines
        (s, slow, engines) = await read(excerpt(700), rate: 1, slowRTF: 4) { s, slow in
            await until(10) { slow.calls == 2 && slow.isBusy }
            try? await Task.sleep(nanoseconds: 300_000_000)
            s.setRate(3)
        }
        describe("2 watchdog 1x -> 3x", s, slow)
        check("2: read finished, every token once in order", whole(s))
        check("2: switched with the 3x message", s.fallbackReason == "Switched to Kokoro to keep up at 3×")
        // The slow engine is never asked again after the switch, so its last text is the abandoned chunk.
        check("2: the chunk in flight was cancelled", slow.cancelled == 1)
        check("2: the fallback remade that same chunk", (engines.neural as! FakeEngine).texts.first == slow.lastText
              && s.made.filter { $0.voice == slowVoice.id }.count == slow.calls - 1)
        check("2: hand-over contiguous", handover(s))
        check("2: no starvation", s.player.starvations == 0)

        // 3. A slow engine with headroom (4x real time) keeps up at 2.5x: chunks grow from the opening chunk, no fallback.
        (s, slow, _) = await read(excerpt(700), rate: 2.5, slowRTF: 4)
        describe("3 keeps up at 2.5x", s, slow)
        check("3: read finished, every token once in order", whole(s))
        check("3: no fallback", s.fallbackReason == nil && s.made.allSatisfy { $0.voice == slowVoice.id })
        check("3: chunks grow after the opening chunk", (s.made.map(\.tokens.count).max() ?? 0) > s.made[0].tokens.count)
        check("3: no starvation", s.player.starvations == 0)

        // 4. Cancellation, busy and unload: stop mid-chunk, then unload, then a new read reloads the engine first.
        var busyMid = false, callsAtStop = 0
        (s, slow, engines) = await read(excerpt(500), rate: 1, slowRTF: 2, timeout: 2) { s, slow in
            await until(10) { slow.calls == 2 && slow.isBusy }
            busyMid = true
            s.stop()
            callsAtStop = slow.calls
        }
        check("4: busy while a chunk is in flight", busyMid)
        await until(2) { !engines.isBusy }
        check("4: stop cancels the chunk in flight and frees the engine", slow.cancelled == 1 && !engines.isBusy && s.state == .finished)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        check("4: nothing synthesised after stop", slow.calls == callsAtStop)
        engines.unloadAll()
        let fast = engines.neural as! FakeEngine
        check("4: unloadAll unloads every engine", slow.unloads == 1 && fast.unloads == 1 && !slow.loaded)
        let preparesBefore = slow.prepares
        (s, slow, _) = await read(excerpt(250), rate: 1, slowRTF: 4, engines: engines)
        describe("4 read after unload", s, slow)
        check("4: the next read prepares (reloads) first and finishes", slow.prepares == preparesBefore + 1 && slow.unloadedSynths == 0 && whole(s))

        // 5. Sol inspection 4 #2: the idle timer unloads everything during a long pause, so the Kokoro fallback is cold
        // (a 1.5 s load here). Resuming re-warms it; when the engine then falls behind (as Qwen3 reloading would) at 2x,
        // the watchdog's hand-over costs one warm chunk, not a load in front of an empty buffer.
        let coldFast = FakeEngine(kind: .neural, realTime: 60, coldLoad: 1.5)
        engines = Engines(neural: coldFast, system: SystemEngine(), qwen: FakeEngine(kind: .qwen, realTime: 6))
        (s, slow, _) = await read(excerpt(400), rate: 1, slowRTF: 6, engines: engines) { s, slow in
            await until(10) { coldFast.loaded && s.state == .playing && s.player.queuedUntil - s.player.currentTime >= 8 }
            s.pause()
            engines.unloadAll()
            try? await Task.sleep(nanoseconds: 300_000_000)
            slow.realTime = 0.2
            s.resume()
            s.setRate(2)
        }
        describe("5 cold fallback after an idle unload", s, slow)
        check("5: read finished, every token once in order", whole(s))
        check("5: resuming prepared the unloaded fallback again", coldFast.prepares == 2)
        check("5: handed over to the fallback, contiguous", s.effectiveVoice == fastVoice && handover(s))
        check("5: no starvation", s.player.starvations == 0)

        // 6. Sol inspection 4 #3: French stays French. Without a Kokoro fallback a French slow read hands over to a French
        // system voice, and a failing French Kokoro chunk is retried with one (never the English default, id "").
        func french(_ id: String) -> Bool { AVSpeechSynthesisVoice(identifier: id)?.language.hasPrefix("fr") == true }
        let frSlow = Voice(id: "fake.slow", name: "Fake slow", accent: "", gender: "Female", engine: .qwen, installed: true, language: "fr")
        var system = FakeEngine(kind: .system, realTime: 60)
        (s, slow, _) = await read(excerpt(450), rate: 2.5, slowRTF: 1.5, engines: Engines(neural: FakeEngine(kind: .neural, realTime: 60), system: system,
                                  qwen: FakeEngine(kind: .qwen, realTime: 1.5)), voice: frSlow, fallback: nil)
        describe("6 French without Kokoro", s, slow)
        check("6: a French slow read hands over to a French system voice (\(s.effectiveVoice.name))",
              whole(s) && french(s.effectiveVoice.id) && !system.voiceIDs.isEmpty && system.voiceIDs.allSatisfy(french))
        system = FakeEngine(kind: .system, realTime: 60)
        let frKokoro = Voice(id: "ff_fake", name: "Fake Siwis", accent: "", gender: "Female", engine: .neural, installed: true, language: "fr")
        (s, _, _) = await read(excerpt(200), rate: 2.5, slowRTF: 4, engines: Engines(neural: FakeEngine(kind: .neural, realTime: 60, failing: true),
                               system: system, qwen: FakeEngine(kind: .qwen, realTime: 4)), voice: frKokoro, fallback: nil)
        check("6: a failing French Kokoro chunk is retried with a French system voice", whole(s) && !system.voiceIDs.isEmpty && system.voiceIDs.allSatisfy(french))

        // 7. An engine that keeps up to 1.5x (as Breeze): a read started above that starts on the fallback, never asks the
        // slow engine (no prepare, no chunk) and stays there when the rate drops; at the limit itself it starts as before.
        func limited() -> Engines { Engines(neural: FakeEngine(kind: .neural, realTime: 60), system: SystemEngine(), qwen: FakeEngine(kind: .qwen, realTime: 4, keepsUpTo: 1.5)) }
        (s, slow, _) = await read(excerpt(250), rate: 2.5, slowRTF: 4, engines: limited()) { s, _ in s.setRate(1) }   // ~20 s at 1x
        describe("7 above the limit", s, slow)
        check("7: above its limit the read starts on the fallback, with the reason", whole(s) && s.made.allSatisfy { $0.voice == fastVoice.id }
              && s.fallbackReason == "Qwen3 keeps up to 1.5×; Kokoro is reading at 2.5×" && s.effectiveVoice == fastVoice && s.voice == slowVoice)
        check("7: the limited engine is never prepared or asked, also after the rate drops to 1x", slow.prepares == 0 && slow.calls == 0)
        check("7: first audio as the fallback's, no starvation", (s.firstAudioMs ?? .max) < 1000 && s.player.starvations == 0)
        (s, slow, _) = await read(excerpt(250), rate: 1.5, slowRTF: 4, engines: limited())
        describe("7 at the limit", s, slow)
        check("7: at its limit the read starts on the engine as before", whole(s) && s.made.first?.voice == slowVoice.id && slow.prepares == 1)

        let pass = checks.allSatisfy(\.1)
        print("fake-engine checks: \(checks.filter(\.1).count)/\(checks.count) passed")
        print("V3 fake engines: \(pass ? "PASS" : "FAIL") (fallback boundary, mid-chunk rate change, keep-up, cancellation, unload, cold fallback after an idle unload, French system fallback, start on the fallback above an engine's limit; 0 starvations, no duplicated or skipped tokens)")
        return pass ? 0 : 1
    }

    /// Process memory as Activity Monitor shows it (phys_footprint), in MB.
    static func footprint() -> Double {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return Double(info.ri_phys_footprint) / 1e6
    }

    /// The GPU's "Device Utilization %" from the IOAccelerator registry entry (whole GPU, every process).
    static func gpuUtilisation() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-d", "1", "-c", "IOAccelerator"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let r = out.range(of: "\"Device Utilization %\"=") else { return nil }
        return Int(out[r.upperBound...].prefix { $0.isNumber })
    }

    // MARK: - Helpers

    /// Assert-style checks of the Kokoro word grouping, the stop guard and the downloader (no model needed).
    private static func helperChecks() async -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) { if !c { print("helper check failed: \(what)"); ok = false } }
        // BOS a b _ c , _ d . EOS with frames 2 3 3 1 4 2 1 5 6 2 at 25 ms
        let g = NeuralEngine.groups(ids: [0, 50, 51, 16, 52, 3, 16, 60, 4, 0], durations: [2, 3, 3, 1, 4, 2, 1, 5, 6, 2], frame: 0.025)
        let expected = [(0.05, 0.2), (0.225, 0.325), (0.4, 0.525)]
        check(g.count == 3 && zip(g, expected).allSatisfy { abs($0.start - $1.0) < 1e-9 && abs($0.end - $1.1) < 1e-9 }, "groups \(g)")
        check(NeuralEngine.words(in: "It’s a.m., forty-two—“quoted” dogs' - ok") == ["It's", "a", "m", "forty-two", "quoted", "dogs", "ok"],
              "words \(NeuralEngine.words(in: "It’s a.m., forty-two—“quoted” dogs' - ok"))")
        let p = NeuralEngine.pair(["one", "forty-two", "x", "two"], [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)], counts: [1, 2, 0, 2], offset: 0, duration: 5)
        check(p.map(\.text) == ["one", "forty", "two", "two"] && p[1].start == 1 && p[1].end == 2 && p[2].start == 2 && p[2].end == 3
              && p[3].start == 3 && p[3].end == 5, "pair by counts \(p)")
        // Sol #9: a compound spoken as one group is split by length, so every source token of it gets its own time.
        let c = NeuralEngine.pair(["A", "well-known", "state-of-the-art", "fact"], [(0, 0.2), (0.3, 1.2), (1.3, 2.6), (2.7, 3)], counts: nil, offset: 0, duration: 3)
        check(c.map(\.text) == ["A", "well", "known", "state", "of", "the", "art", "fact"] && abs(c[1].end - 0.7) < 1e-9 && c[2].start == c[1].end
              && c[2].end == 1.2 && abs(c[3].end - 1.8) < 1e-9 && c[6].end == 2.6, "compound split \(c)")
        let s = "A well-known, state-of-the-art fact."
        let timed = Timeline.timings(chunkTokens: TextKit.tokenize(s), chunkTokenOffset: 0, speakable: Speakable.make(s, range: 0 ..< s.utf16.count, lexicon: [:]),
                                     spoken: c, offset: 0, chunkDuration: 3)
        check(timed.count == 8 && zip(timed, c).allSatisfy { abs($0.start - $1.start) < 1e-9 && abs($0.end - $1.end) < 1e-9 }, "compound timings \(timed)")
        let q = NeuralEngine.pair(["a", "b"], [(0, 1), (1, 2), (2, 3), (3, 4)], counts: nil, offset: -0.5, duration: 4)
        check(q.map(\.text) == ["a", "b"] && q[0].start == 0 && q[1].end == 3.5, "pair proportional \(q)")

        // An Objective-C exception (AVFAudio's "player did not see an IO cycle") comes back as an error with its reason.
        let caught = TRCatchException { NSException(name: .genericException, reason: "probe reason", userInfo: nil).raise() }
        check(caught?.localizedDescription == "probe reason" && TRCatchException({}) == nil, "exception catch: \(String(describing: caught))")

        // Stop guard (PLAN 0.3.0 decision 9): 1 s of tone at 24 kHz, then silence.
        let tone = (0 ..< 24_000).map { Float(0.3 * sin(Double($0) * 0.1)) }
        let quiet = [Float](repeating: 0, count: 24_000)
        check(Aligner.keptSamples(tone + quiet, sampleRate: 24_000, lastMatchedEnd: 0.9) == 27_600, "stop guard: silent tail cut to 150 ms")
        check(Aligner.keptSamples(tone + quiet.prefix(6_000), sampleRate: 24_000, lastMatchedEnd: 0.9) == 30_000, "stop guard: 250 ms tail kept")
        check(Aligner.keptSamples(tone + quiet, sampleRate: 24_000, lastMatchedEnd: 1.5) == 39_600, "stop guard: never before the last matched word")
        check(Aligner.keptSamples(tone + tone, sampleRate: 24_000, lastMatchedEnd: 0.5) == 48_000, "stop guard: audible tail never cut")
        check(Aligner.keptSamples(tone + quiet, sampleRate: 24_000, lastMatchedEnd: 0) == 27_600, "stop guard: no matched word, silence still trimmed")

        // Sol inspection 4 #4 through the real spell checker: common words stay, names and misspellings are still corrected.
        let v = ["contract": "contract", "Kestrelco": "Kestrelco", "Nkanabassi": "Nkanabassi", "Dembélé": "Dembélé", "Vitinha": "Vitinha",
                 "Donoghue": "Donoghue", "Lord Atkin": "Lord Atkin", "João Neves": "João Neves"]
        for (said, want) in [("please contact the team", "Please contact the team"), ("email the kestralco team", "Email the Kestrelco team"),
                             ("This is Junyung Kanabasi from Kestralko.", "This is Junyung Nkanabassi from Kestrelco."),
                             ("Dembele and Vitinho scored", "Dembélé and Vitinha scored"),
                             ("In Donahue vs. Stevenson, Lord Atkins set out", "In Donoghue vs. Stevenson, Lord Atkin set out"),
                             ("with Joan Nevis behind them", "With João Neves behind them")] {
            let got = await MainActor.run { Cleanup.apply(said, vocabulary: v, removeFillers: true, isWord: DictationController.isCommonWord) }
            check(got == want, "near miss with the spell checker: \"\(said)\" gave \"\(got)\"")
        }

        // Downloader (PLAN 0.3.0 decision 6): Hugging Face hosts over https only; staged, size-checked, moved.
        for (u, want) in [("https://huggingface.co/x", true), ("https://cdn-lfs.huggingface.co/x", true), ("https://cas-bridge.xethub.hf.co/x", true),
                          ("http://huggingface.co/x", false), ("https://evilhuggingface.co/x", false), ("https://huggingface.co.evil.com/x", false),
                          ("https://hf.co.evil.com/x", false), ("https://github.com/x", false)] {
            check(ModelDownload.allowed(URL(string: u)) == want, "redirect rule for \(u)")
        }
        let dl = outDir.appendingPathComponent("download-check", isDirectory: true)
        let src = dl.appendingPathComponent("src", isDirectory: true), dst = dl.appendingPathComponent("Models/model", isDirectory: true)
        try? FileManager.default.removeItem(at: dl)
        try? FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try? Data(count: 1000).write(to: src.appendingPathComponent("sub/b.bin"))
        do {
            try await ModelDownload.fetch([("a.txt", 5), ("sub/b.bin", 1000)], from: src, into: dst) { _ in }
            check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub/b.bin").path)
                  && !FileManager.default.fileExists(atPath: dl.appendingPathComponent("Models/.model.partial").path), "download: staged then moved")
            // Sol inspection 4 #5: no staging folder (gigabytes for Qwen3) survives a failure or a cancel.
            let staging = dl.appendingPathComponent("Models/.model.partial")
            do {
                try await ModelDownload.fetch([("a.txt", 5), ("sub/b.bin", 999)], from: src, into: dst) { _ in }
                check(false, "download: a size mismatch must fail")
            } catch {
                check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub/b.bin").path), "download: a failed fetch leaves the installed copy")
                check(!FileManager.default.fileExists(atPath: staging.path), "download: a size mismatch leaves no staging folder")
            }
            do {
                try await ModelDownload.fetch([("a.txt", 5), ("missing.bin", 1)], from: src, into: dst) { _ in }
                check(false, "download: a missing file must fail")
            } catch { check(!FileManager.default.fileExists(atPath: staging.path), "download: a failed transfer leaves no staging folder") }
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await ModelDownload.fetch([("a.txt", 5), ("sub/b.bin", 1000)], from: src, into: dst) { _ in }
            }
            let threw = (try? await cancelled.value) == nil
            check(threw && !FileManager.default.fileExists(atPath: staging.path),
                  "download: a cancelled download fails and leaves no staging folder")
        } catch { check(false, "download from file URLs: \(error)") }
        try? FileManager.default.removeItem(at: dl)
        return ok
    }

    /// Reference-free timing check: for words whose start is within 150 ms of an energy onset that follows at least
    /// 40 ms of silence (5 ms RMS below -34 dB of peak), our start minus that onset.
    static func onsetErrors(_ audio: [Float], starts: [Double]) -> [Double] {
        let hop = 120   // 5 ms at 24 kHz
        let env: [Float] = stride(from: 0, to: audio.count, by: hop).map { i in
            let s = audio[i ..< min(i + hop, audio.count)]
            return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
        }
        let threshold = (env.max() ?? 0) * powf(10, -34 / 20)
        return starts.compactMap { start in
            let i = Int(start * 200)
            guard let j = (max(i - 30, 8) ..< min(i + 30, env.count)).first(where: { j in
                env[j] >= threshold && (1 ... 8).allSatisfy { env[j - $0] < threshold }
            }) else { return nil }
            return start - Double(j) / 200
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count - 1) * p + 0.5), sorted.count - 1)]
    }

    /// Words after NeMo normalisation (digits -> words), case and punctuation folded: what `wer` and `wordDiff` compare.
    private static func words(_ s: String, _ language: String) -> [String] {
        NemoTextNormalizer.normalize(s, language: language == "fr" ? .french : .english).lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Word error rate after the same NeMo normalisation on both sides (digits -> words), case and punctuation folded.
    static func wer(reference: String, hypothesis: String, language: String = "en") -> Double {
        let r = words(reference, language), h = words(hypothesis, language)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var row = Array(0 ... h.count)
        for i in 1 ... r.count {
            var next = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            row = next
        }
        return Double(row[h.count]) / Double(r.count)
    }

    /// `wer` plus the longest runs of consecutive words missing from the hypothesis and added to it, along one optimal
    /// alignment (substitutions preferred), so a dropped or repeated sentence shows as a run however low the WER.
    static func wordDiff(reference: String, hypothesis: String, language: String = "en") -> (wer: Double, missing: Int, extra: Int, worst: String) {
        let r = words(reference, language), h = words(hypothesis, language)
        var d = [[Int]](repeating: [Int](repeating: 0, count: h.count + 1), count: r.count + 1)
        for i in 0 ... r.count { d[i][0] = i }
        for j in 0 ... h.count { d[0][j] = j }
        for i in stride(from: 1, through: r.count, by: 1) {
            for j in stride(from: 1, through: h.count, by: 1) {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
        }
        var i = r.count, j = h.count, missing = 0, extra = 0, runM = 0, runE = 0, at = (0, 0)
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) { i -= 1; j -= 1; runM = 0; runE = 0 }
            else if i > 0, d[i][j] == d[i - 1][j] + 1 { i -= 1; runM += 1; runE = 0; if runM > max(missing, extra) { at = (i, j) }; missing = max(missing, runM) }
            else { j -= 1; runE += 1; runM = 0; if runE > max(missing, extra) { at = (i, j) }; extra = max(extra, runE) }
        }
        // The longest run in context: the text's words, then what was heard, around where it starts.
        let worst = "text \"" + r[max(at.0 - 4, 0) ..< min(at.0 + 10, r.count)].joined(separator: " ") + "\" / heard \""
            + h[max(at.1 - 4, 0) ..< min(at.1 + 10, h.count)].joined(separator: " ") + "\""
        return (r.isEmpty ? (h.isEmpty ? 0 : 1) : Double(d[r.count][h.count]) / Double(r.count), missing, extra, worst)
    }

    static func writeWAV(_ samples: [Float], to url: URL, rate: Double = Player.sampleRate) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
    private static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
    private static func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
}

/// Parakeet batch recogniser for the round trip (English v2: its word timestamps track Kokoro audio better than "ultra";
/// French: the multilingual v3 from a folder already on disk, never downloaded here).
private struct Recogniser {
    let manager: AsrManager

    static func load(v3: URL? = nil) async throws -> Recogniser {
        let models = if let v3 { try await AsrModels.load(from: v3, version: .v3) } else { try await AsrModels.downloadAndLoad(version: .v2) }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Recogniser(manager: manager)
    }

    func transcribe(_ samples24k: [Float], language: String = "en") async throws -> (text: String, words: [(word: String, start: Double, end: Double)]) {
        let samples = try AudioConverter().resample(samples24k, from: Player.sampleRate)
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language == "fr" ? .french : nil)
        return (result.text, buildWordTimings(from: result.tokenTimings ?? []).map { ($0.word, $0.startTime, $0.endTime) })
    }
}

/// A test engine `realTime` times faster than real time (a cancellable sleep, plus 0.15 s per chunk for a non-Kokoro
/// kind, plus `coldLoad` when called unloaded), 15 characters of speech per second of silent audio, words at their exact
/// speakable ranges; `failing` throws instead. Records every call; state behind `lock`.
private final class FakeEngine: SpeechEngine, @unchecked Sendable {
    let kind: EngineKind
    let coldLoad: Double, failing: Bool, keepsUpTo: Float?
    private let lock = NSLock()
    private var _texts: [String] = [], _voiceIDs: [String] = [], _cancelled = 0, _prepares = 0, _unloads = 0, _inFlight = 0, _loaded = false,
                _unloadedSynths = 0, _realTime: Double

    init(kind: EngineKind, realTime: Double, coldLoad: Double = 0, failing: Bool = false, keepsUpTo: Float? = nil) {
        self.kind = kind; _realTime = realTime; self.coldLoad = coldLoad; self.failing = failing; self.keepsUpTo = keepsUpTo
    }

    /// Settable mid-read: a lower value makes the engine fall behind from its next chunk.
    var realTime: Double { get { lock.withLock { _realTime } } set { lock.withLock { _realTime = newValue } } }
    var voiceIDs: [String] { lock.withLock { _voiceIDs } }
    var texts: [String] { lock.withLock { _texts } }
    var calls: Int { texts.count }
    var lastText: String { texts.last ?? "" }
    var cancelled: Int { lock.withLock { _cancelled } }
    var prepares: Int { lock.withLock { _prepares } }
    var unloads: Int { lock.withLock { _unloads } }
    var loaded: Bool { lock.withLock { _loaded } }
    /// Synthesis asked of an unloaded engine without a prepare first.
    var unloadedSynths: Int { lock.withLock { _unloadedSynths } }
    var isBusy: Bool { lock.withLock { _inFlight > 0 } }

    func voices() async -> [Voice] { [] }
    func prepare(voice: String) async throws {
        if lock.withLock({ _prepares += 1; return !_loaded }) { try await Task.sleep(nanoseconds: UInt64(coldLoad * 1e9)) }
        lock.withLock { _loaded = true }
    }
    func unload() { lock.withLock { _unloads += 1; _loaded = false } }

    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let cold = lock.withLock { _texts.append(text); _voiceIDs.append(voice); _inFlight += 1; if !_loaded { _unloadedSynths += 1 }; return !_loaded }
        defer { lock.withLock { _inFlight -= 1 } }
        if failing { throw SpeechError.badAudio }
        let seconds = Double(text.utf16.count) / 15
        let work = (cold ? coldLoad : 0) + (kind == .neural ? 0 : 0.15) + seconds / realTime   // a slow engine's fixed cost per chunk, as Qwen3's
        do { try await Task.sleep(nanoseconds: UInt64(work * 1e9)) } catch { lock.withLock { _cancelled += 1 }; throw error }
        if cold { lock.withLock { _loaded = true } }
        let tokens = TextKit.tokenize(text)
        let words = tokens.enumerated().map { i, t in
            SpokenWord(text: t.text, start: seconds * Double(i) / Double(tokens.count), end: seconds * Double(i + 1) / Double(tokens.count), range: t.range)
        }
        return SynthChunk(samples: [Float](repeating: 0, count: Int(seconds * Player.sampleRate)), sampleRate: Player.sampleRate, words: words)
    }
}

/// The chunks a read's engines returned, in order across engines: what the session queued, bar a late result it dropped.
private final class ChunkLog: @unchecked Sendable {   // `_entries` only behind `lock`
    private let lock = NSLock()
    private var _entries: [(voice: String, text: String, samples: [Float], sampleRate: Double, work: Double)] = []
    var entries: [(voice: String, text: String, samples: [Float], sampleRate: Double, work: Double)] { lock.withLock { _entries } }
    func add(_ voice: String, _ text: String, _ c: SynthChunk, _ work: Double) { lock.withLock { _entries.append((voice, text, c.samples, c.sampleRate, work)) } }
}

/// Forwards everything to `engine` and logs every chunk it returns (the sustained runs hear the queued audio back).
private final class LoggingEngine: SpeechEngine {
    let engine: SpeechEngine, log: ChunkLog
    init(_ engine: SpeechEngine, _ log: ChunkLog) { self.engine = engine; self.log = log }
    var kind: EngineKind { engine.kind }
    var isBusy: Bool { engine.isBusy }
    func voices() async -> [Voice] { await engine.voices() }
    func prepare(voice: String) async throws { try await engine.prepare(voice: voice) }
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let started = Date()
        let c = try await engine.synthesize(text, voice: voice)
        log.add(voice, text, c, Date().timeIntervalSince(started))
        return c
    }
    func unload() { engine.unload() }
    var keepsUpTo: Float? { engine.keepsUpTo }
}
