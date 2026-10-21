// Headless self-tests (no windows, no live audio except the volume-0 R10 run).
// `--selftest-tts <file> [--voice id] [--rate x]`: synthesises every chunk with the neural engine, builds timings as
// ReadSession does, transcribes the audio with Parakeet and reports word-start error against the recogniser (R2); with
// `--rate`, renders through the production Player graph offline and checks WER and the media clock (R3).
// `--selftest-tts [<file>] --long`: 100k characters through a real ReadSession at volume 0 for 20 s (R10).
// `--selftest-asr <dir>`: WP5's dictation fixtures.
import AVFoundation
import FluidAudio
import Foundation
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
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            guard helperChecks() else { return 1 }
            if args.contains("--long") { return try await longRun(text, voice: voice) }
            return try await timingRun(text, voice: voice, rate: value("--rate").flatMap(Float.init))
        } catch {
            print("selftest-tts: error \(error)")
            return 1
        }
    }

    /// Transcribes every audio file in the directory and reports WER. Returns the process exit code.
    static func asr(directory: String) async -> Int32 {
        FileHandle.standardError.write(Data("--selftest-asr \(directory): not implemented yet (WP3)\n".utf8))
        return 2
    }

    // MARK: - R2 / R3

    @MainActor private static func timingRun(_ text: String, voice: String, rate: Float?) async throws -> Int32 {
        let tokens = TextKit.tokenize(text)
        let chunks = TextKit.chunks(text, tokens: tokens)
        let engine = NeuralEngine()
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
            let speakable = Speakable.make(text, range: chunk.range, lexicon: [:])
            clock = Date()
            let s = try await engine.synthesize(speakable.text, voice: voice)
            synthSeconds += Date().timeIntervalSince(clock)
            if k == 0 { firstChunkMs = ms(since: clock) }
            // Same arithmetic as ReadSession: offset = media start of the chunk, duration = its samples.
            let offset = Double(audio.count) / Player.sampleRate
            let duration = Double(s.samples.count) / s.sampleRate
            audio += s.samples
            synths.append(s)
            speakables.append(speakable.text)
            timings += Timeline.timings(chunkTokens: Array(tokens[chunk.tokens]), chunkTokenOffset: chunk.tokens.lowerBound,
                                        speakable: speakable, spoken: s.words, offset: offset, chunkDuration: duration)
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

        // Recogniser round trip.
        let asr = try await Recogniser.load()
        let heard = try await asr.transcribe(audio)
        let assign = Alignment.assign(spoken: heard.words.map(\.word), source: tokens.map(\.text))
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
        let wer1 = wer(reference: reference, hypothesis: heard.text)

        print("words: \(tokens.count) tokens, \(spoken) timed, \(signed.count) matched to the recogniser (\(pct(Double(signed.count) / Double(max(spoken, 1)))))")
        print("start error |ours - ASR|: median \(Int(median.rounded())) ms, p90 \(Int(p90.rounded())) ms; signed median \(Int((percentile(signed.sorted(), 0.5) * 1000).rounded())) ms (ours minus ASR)")
        let onset = onsetErrors(audio, starts: timings.filter { $0.end > $0.start }.map(\.start))
        print("acoustic check (no recogniser): \(onset.count) words after silence, ours - energy onset median \(Int((percentile(onset.sorted(), 0.5) * 1000).rounded())) ms, p90 |.| \(Int((percentile(onset.map(abs).sorted(), 0.9) * 1000).rounded())) ms")
        print("WER (ASR vs spoken text, 1x): \(pct(wer1))")
        print("first-chunk synthesis: \(firstChunkMs) ms; RTF \(String(format: "%.3f", synthSeconds / audioSeconds)) (\(fmt(synthSeconds)) s for \(fmt(audioSeconds)) s of audio, \(chunks.count) chunks)")
        print("invariants: \(problems.isEmpty ? "ok" : problems.prefix(10).joined(separator: "; "))")
        var pass = problems.isEmpty && signed.count >= 200 && median <= 60 && p90 <= 150
        print("R2: \(pass ? "PASS" : "FAIL") (median <= 60 ms, p90 <= 150 ms, >= 200 matched words, invariants)")

        if let rate {
            let clock1 = try clockError(rate: 1), clockR = try clockError(rate: rate)
            print("clock vs rendered clicks: 1x mean \(Int(clock1.mean * 1000)) ms max |err| \(Int(clock1.maxAbs * 1000)) ms; \(rate)x mean \(Int(clockR.mean * 1000)) ms max |err| \(Int(clockR.maxAbs * 1000)) ms (\(clockR.count) clicks)")
            let player = Player(manualRendering: true)
            player.rate = rate
            for s in synths { player.enqueue(s) }
            player.play()
            let rendered = try player.renderOffline(seconds: audioSeconds / Double(rate) + 0.5)
            try writeWAV(rendered, to: outDir.appendingPathComponent("tts-\(rate)x.wav"))
            let heardR = try await asr.transcribe(rendered)
            let werR = wer(reference: reference, hypothesis: heardR.text)
            let ok = werR <= 0.08 && clockR.maxAbs <= 0.020 && clockR.count >= 10
            print("WER at \(rate)x through the Player graph: \(pct(werR))")
            print("R3: \(ok ? "PASS" : "FAIL") (WER <= 8 %, clock within 20 ms)")
            pass = pass && ok
        }
        print("wrote \(outDir.path)/tts.wav, tts-words.tsv")
        return pass ? 0 : 1
    }

    /// Renders a click train through the production graph and compares where each click comes out with what the
    /// clock said at that output sample. Positive mean = clock ahead of the audio.
    @MainActor static func clockError(rate: Float) throws -> (mean: Double, maxAbs: Double, count: Int) {
        let sr = Player.sampleRate
        let times = stride(from: 0.5, through: 5.5, by: 0.5).map { $0 }
        var clicks = [Float](repeating: 0, count: Int(6 * sr))
        for t in times {
            for j in 0 ..< 120 {   // 5 ms 2 kHz burst, Hann-windowed
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / 119)
                clicks[Int(t * sr) + j] = Float(0.8 * w * sin(2 * Double.pi * 2000 * Double(j) / sr))
            }
        }
        let player = Player(manualRendering: true)
        player.rate = rate
        player.enqueue(SynthChunk(samples: clicks, sampleRate: sr, words: []))
        player.play()
        var out: [Float] = []
        var readings: [(index: Int, clock: Double)] = []
        while Double(out.count) < (6 / Double(rate) + 0.3) * sr {
            let blockStart = out.count
            out += try player.renderOffline(seconds: 0.01)
            readings.append((blockStart, player.currentTime))
        }
        let peak = out.map(abs).max() ?? 0
        var onsets: [Int] = []
        var i = 0
        while i < out.count {
            if abs(out[i]) > 0.2 * peak { onsets.append(i); i += Int(0.25 * sr / Double(rate)) } else { i += 1 }
        }
        guard onsets.count == times.count else { throw SpeechError.render("found \(onsets.count) clicks, expected \(times.count)") }
        let errors = zip(onsets, times).map { k, media -> Double in
            let r = readings.last { $0.index <= k }!
            return r.clock + Double(k - r.index) / sr * Double(rate) - media
        }
        return (errors.reduce(0, +) / Double(errors.count), errors.map(abs).max() ?? 0, errors.count)
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
        var seekLanded = false
        for second in 1 ... 20 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if second == 8 { session.setRate(2) }
            if second == 12 { session.seek(token: 1000) }
            if second == 14 { seekLanded = (1000 ..< 1100).contains(session.currentToken ?? -1) }
            log.append("\(second)s:\(session.currentToken.map(String.init) ?? "-")")
        }
        let state = session.state
        session.stop()
        let first = session.firstAudioMs ?? .max
        let pass = state == .playing && session.player.starvations == 0 && first < 1000 && seekLanded
        print("long text: \(text.utf16.count) characters, \(session.tokens.count) tokens")
        print("token per second (2x from 8 s, seek to 1000 at 12 s): \(log.joined(separator: " "))")
        print("first audio \(first) ms; starvations \(session.player.starvations); state after 20 s \(state); seek landed \(seekLanded)")
        print("R10: \(pass ? "PASS" : "FAIL") (first audio < 1000 ms, starvations 0)")
        return pass ? 0 : 1
    }

    // MARK: - Helpers

    /// Assert-style checks of the Kokoro word grouping (no model needed).
    private static func helperChecks() -> Bool {
        var ok = true
        func check(_ c: Bool, _ what: String) { if !c { print("helper check failed: \(what)"); ok = false } }
        // BOS a b _ c , _ d . EOS with frames 2 3 3 1 4 2 1 5 6 2 at 25 ms
        let g = NeuralEngine.groups(ids: [0, 50, 51, 16, 52, 3, 16, 60, 4, 0], durations: [2, 3, 3, 1, 4, 2, 1, 5, 6, 2], frame: 0.025)
        let expected = [(0.05, 0.2), (0.225, 0.325), (0.4, 0.525)]
        check(g.count == 3 && zip(g, expected).allSatisfy { abs($0.start - $1.0) < 1e-9 && abs($0.end - $1.1) < 1e-9 }, "groups \(g)")
        check(NeuralEngine.words(in: "It’s a.m., forty-two—“quoted” dogs' - ok") == ["It's", "a", "m", "forty-two", "quoted", "dogs", "ok"],
              "words \(NeuralEngine.words(in: "It’s a.m., forty-two—“quoted” dogs' - ok"))")
        let p = NeuralEngine.pair(["one", "forty-two", "x", "two"], [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)], counts: [1, 2, 0, 2], offset: 0, duration: 5)
        check(p.map(\.text) == ["one", "forty-two", "two"] && p[1].start == 1 && p[1].end == 3 && p[2].start == 3 && p[2].end == 5, "pair by counts \(p)")
        let q = NeuralEngine.pair(["a", "b"], [(0, 1), (1, 2), (2, 3), (3, 4)], counts: nil, offset: -0.5, duration: 4)
        check(q.map(\.text) == ["a", "b"] && q[0].start == 0 && q[1].end == 3.5, "pair proportional \(q)")
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
        sorted.isEmpty ? .nan : sorted[min(Int(Double(sorted.count - 1) * p + 0.5), sorted.count - 1)]
    }

    /// Word error rate after the same NeMo normalisation on both sides (digits -> words), case and punctuation folded.
    static func wer(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            NemoTextNormalizer.normalize(s, language: .english).lowercased()
                .replacingOccurrences(of: "’", with: "'")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
                .filter { !$0.isEmpty }
        }
        let r = words(reference), h = words(hypothesis)
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

    static func writeWAV(_ samples: [Float], to url: URL, rate: Double = Player.sampleRate) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
    private static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
    private static func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
}

/// Parakeet batch recogniser for the round trip (English v2: its word timestamps track Kokoro audio better than "ultra").
private struct Recogniser {
    let manager: AsrManager

    static func load() async throws -> Recogniser {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Recogniser(manager: manager)
    }

    func transcribe(_ samples24k: [Float]) async throws -> (text: String, words: [(word: String, start: Double, end: Double)]) {
        let samples = try AudioConverter().resample(samples24k, from: Player.sampleRate)
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return (result.text, buildWordTimings(from: result.tokenTimings ?? []).map { ($0.word, $0.startTime, $0.endTime) })
    }
}
