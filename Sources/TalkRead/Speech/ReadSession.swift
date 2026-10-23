// One read: chunks -> synthesis ahead of playback -> player -> timeline -> highlight ticks.
// A producer task synthesises up to three chunks ahead; a 30 Hz main-actor tick maps the player's media clock to the
// current token. Seek, skip and voice change restart synthesis at a token (PLAN decision 15); rate is instant.
// Slow engines (Qwen3) get bounded chunks sized by a time budget and a watchdog on the chunk in flight; when they cannot
// keep up, the rest of the read goes to the warm Kokoro fallback without restarting speech (PLAN 0.3.0, Sol revisions 2,
// 2b and 4). Kokoro-only reads take exactly the 1.0 path.
import Foundation
import TalkReadCore

@MainActor final class ReadSession: ObservableObject {
    enum State: Equatable { case preparing, playing, paused, finished, failed(String) }
    @Published private(set) var state: State = .preparing
    @Published private(set) var currentToken: Int?
    @Published private(set) var currentSentence: Int?
    let text: String
    let tokens: [Token]
    let capture: Capture?
    var firstAudioMs: Int?
    let player = Player()
    private(set) var voice: Voice
    /// The voice actually speaking now: `voice`, or the Kokoro fallback once the engine fell behind (V3). The UI shows it.
    @Published private(set) var effectiveVoice: Voice
    /// Why the read switched to the fallback voice, shown in the player until the read ends; nil otherwise.
    @Published private(set) var fallbackReason: String?
    /// Media-time timings of every chunk queued since the last (re)start, in order.
    private(set) var timings: [TalkReadCore.WordTiming] = []
    /// Which voice made each chunk queued since the last (re)start (self-test evidence).
    private(set) var made: [(tokens: Range<Int>, voice: String)] = []

    /// Slow-engine chunk sizes in UTF-16 characters: a short opening chunk for first audio within 1.5 s, then at most
    /// `slowChars`; a chunk the budget cannot fit to `minSlowChars` goes to the fallback.
    static let openingChars = 60, slowChars = 160, minSlowChars = 25
    /// Buffered playback a slow chunk must leave when ready: the watchdog's deadline (the fallback's fixed 0.2 s plus its
    /// per-character time, plus 0.3 s) and the plan's 0.5 s to spare beyond it. Measured 23 Oct: with 0.5 (finishing on
    /// the deadline itself) ordinary chunk-to-chunk variance tripped the watchdog even at 2x; with 1.0 Qwen3 read 60 s at 2x.
    static let spare = 1.0

    private let engines: Engines
    private let lexicon: [String: String]
    private let startToken: Int
    private let fallback: Voice?
    private var producer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var chunkEnds: [Double] = []
    private var doneEnqueueing = false
    private var userPaused = false
    private var needsRestart = false
    private var generation = 0
    private var startedAt: Date?
    /// Measured seconds of work per spoken (speakable) character: the slow engine's (synthesis plus alignment) and the
    /// fallback's. Spoken characters, because "14 March 2027" costs what "the fourteenth of March twenty twenty-seven" does.
    private var slowSecondsPerChar: Double?
    // ponytail: seeded from the R2 run of 23 Oct (Kokoro .legacy, M3 Max: 6.4 s of work for about 2,000 spoken
    // characters, first chunk 0.2 s), rounded up; replaced by measurement once the fallback speaks.
    private var fallbackSecondsPerChar = 0.004

    /// `fallback`: the Kokoro voice of the same language the read switches to if `voice`'s engine cannot keep up (V3).
    init(text: String, capture: Capture?, voice: Voice, rate: Float, startToken: Int, engines: Engines, lexicon: [String: String], fallback: Voice? = nil) {
        self.text = text
        self.tokens = TextKit.tokenize(text)
        self.capture = capture
        self.voice = voice
        self.effectiveVoice = voice
        self.engines = engines
        self.lexicon = lexicon
        self.startToken = startToken
        self.fallback = fallback
        player.rate = rate
        player.onInterrupted = { [weak self] in
            // Device change, paused or not: the player dropped its queue, so the producer and its bookkeeping are stale.
            // Stop them; resume restarts synthesis at the word that was playing.
            guard let self, [State.playing, .preparing, .paused].contains(self.state) else { return }
            self.generation += 1
            self.producer?.cancel()
            self.needsRestart = true
            self.userPaused = true
            self.state = .paused
        }
    }

    func start() {
        startedAt = Date()
        if let fallback, engines.engine(for: voice).isSlow {
            // Warm now, so a switch costs one Kokoro chunk, not a model load.
            let engine = engines.engine(for: fallback)
            Task { do { try await engine.prepare(voice: fallback.id) } catch { Log.write("read: fallback warm-up failed: \(error)") } }
        }
        restart(from: startToken)
        // Queued behind the producer, so the engine starts while the first chunk is synthesised off the main actor;
        // skipped when the read already finished (nothing speakable) or was paused (nothing would stop the engine).
        Task { [weak self] in if let self, state == .preparing { player.warmUp() } }
    }

    func pause() {
        guard state == .playing || state == .preparing else { return }
        userPaused = true
        player.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        userPaused = false
        if needsRestart {
            restart(from: currentToken ?? startToken)
        } else if chunkEnds.isEmpty {
            state = .preparing   // first chunk still synthesising; it starts playing when queued
        } else {
            startPlayback()
        }
    }

    func stop() {
        generation += 1
        producer?.cancel()
        ticker?.cancel()
        player.reset()
        if state != .finished { state = .finished }
    }

    func skip(sentences: Int) {
        guard let last = tokens.last else { return }
        let current = currentSentence ?? tokens[min(max(startToken, 0), tokens.count - 1)].sentence
        // Clamped before the addition: any Int arrives from the CLI or socket and must not overflow.
        let target = min(max(current + min(max(sentences, -last.sentence - 1), last.sentence + 1), 0), last.sentence)
        if let first = tokens.firstIndex(where: { $0.sentence >= target }) { restart(from: first) }
    }

    func seek(token: Int) {
        guard tokens.indices.contains(token) else { return }
        restart(from: token)
    }

    func setRate(_ r: Float) { player.rate = r }

    func setVoice(_ v: Voice) {
        voice = v
        effectiveVoice = v
        fallbackReason = nil
        guard state != .finished, !tokens.isEmpty else { return }
        let sentence = currentSentence ?? tokens[min(max(startToken, 0), tokens.count - 1)].sentence
        if let first = tokens.firstIndex(where: { $0.sentence >= sentence }) { restart(from: first) }
    }

    // MARK: - Pipeline

    private func restart(from token: Int) {
        generation += 1
        let gen = generation
        producer?.cancel()
        player.reset()
        timings = []
        made = []
        chunkEnds = []
        doneEnqueueing = false
        needsRestart = false
        if case .failed = state { userPaused = false }
        let chunks = TextKit.chunks(text, tokens: tokens, from: token)
        guard !chunks.isEmpty else { return finish() }
        state = userPaused ? .paused : .preparing
        player.moreComing = true
        producer = Task { [weak self] in await self?.produce(chunks, gen) }
        if ticker == nil || ticker!.isCancelled {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        }
    }

    /// `plan`: Kokoro's sentence-packed chunks from the start token. A slow engine instead cuts one bounded chunk at a
    /// time; after a switch to the fallback the plan is recut from the first unqueued token.
    private func produce(_ plan: [Chunk], _ gen: Int) async {
        var plan = plan[...]
        var next = plan.first!.tokens.lowerBound
        var k = 0
        while next < tokens.count {
            // ponytail: polls the clock every 50 ms to keep at most three chunks queued; a completion-driven wait if
            // 50 ms ever matters (chunks are seconds long).
            while gen == generation, chunkEnds.filter({ $0 > player.currentTime }).count >= 3 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard gen == generation, !Task.isCancelled else { return }
            var chunk: Chunk?, said: Speakable?, synth: SynthChunk?
            let slow = engines.engine(for: effectiveVoice)
            if slow.isSlow, k == 0 {
                // Loaded on selection normally; after an idle unload this reloads before the timed opening chunk.
                do { try await slow.prepare(voice: effectiveVoice.id) } catch {
                    guard gen == generation else { return }
                    Log.write("read: \(effectiveVoice.id) did not load: \(error.localizedDescription)")
                    useFallback("Switched to \(fallbackName) because \(effectiveVoice.name) could not load")
                }
                guard gen == generation, !Task.isCancelled else { return }
            }
            if engines.engine(for: effectiveVoice).isSlow {
                if let c = nextSlowChunk(from: next, opening: k == 0) {
                    chunk = c
                    said = speakable(c)
                    synth = await makeSlow(said!.text, slow, gen)
                    guard gen == generation, !Task.isCancelled else { return }
                } else {
                    useFallback(keepUpReason)
                }
            }
            if synth == nil {
                if chunk == nil {
                    if plan.first?.tokens.lowerBound != next { plan = TextKit.chunks(text, tokens: tokens, from: next)[...] }
                    chunk = plan.removeFirst()
                    said = speakable(chunk!)
                }
                let spoken = said!.text, started = Date()
                do {
                    synth = try await synthesize(spoken)
                } catch {
                    guard gen == generation else { return }
                    Log.write("read: chunk \(k) failed: \(error.localizedDescription)")
                    return fail(error.localizedDescription)
                }
                if effectiveVoice != voice, !spoken.isEmpty {
                    fallbackSecondsPerChar = 0.5 * fallbackSecondsPerChar + 0.5 * Date().timeIntervalSince(started) / Double(spoken.utf16.count)
                }
            }
            guard gen == generation, !Task.isCancelled, let chunk, let said, let synth else { return }
            let start = player.enqueue(synth)
            chunkEnds.append(player.queuedUntil)
            made.append((chunk.tokens, effectiveVoice.id))
            timings += Timeline.timings(chunkTokens: Array(tokens[chunk.tokens]), chunkTokenOffset: chunk.tokens.lowerBound,
                                        speakable: said, spoken: synth.words, offset: start,
                                        chunkDuration: player.queuedUntil - start, language: voice.language)
            if k == 0 { firstAudio() }
            next = chunk.tokens.upperBound
            k += 1
        }
        doneEnqueueing = true
        player.moreComing = false
    }

    private func speakable(_ c: Chunk) -> Speakable { Speakable.make(text, range: c.range, lexicon: lexicon, language: voice.language) }

    /// The next slow chunk under the time budget (PLAN 0.3.0 Sol revision 2): the largest one (at most `slowChars`) whose
    /// measured cost leaves at least `spare` plus the fallback's per-character time for it buffered at the current rate.
    /// Nil when not even a `minSlowChars` chunk fits: that chunk and the rest go to the fallback. Chunks thus grow only
    /// as fast as the engine's measured headroom allows.
    private func nextSlowChunk(from next: Int, opening: Bool) -> Chunk? {
        if opening { return slowChunk(from: next, limit: Self.openingChars) }
        // Paused (nothing drains) or nothing measured yet: the largest chunk; the watchdog covers a later resume.
        guard player.isPlaying, let spc = slowSecondsPerChar else { return slowChunk(from: next, limit: Self.slowChars) }
        var limit = Self.slowChars
        // ponytail: each try re-chunks the rest of the text (linear in it, about 1 ms per 10k characters); a token
        // window if 100k-character reads ever show it.
        while limit >= Self.minSlowChars {
            let c = slowChunk(from: next, limit: limit)
            if Double(speakable(c).text.utf16.count) * (spc + fallbackSecondsPerChar) <= bufferedSeconds - Self.spare { return c }
            limit = limit * 3 / 4
        }
        return nil
    }

    /// The rest of the current sentence (cut at `limit`) plus the whole sentences after it that still fit; a remainder
    /// shorter than `minSlowChars` ("2027." after a cut) always takes the next sentences with it rather than travel alone.
    private func slowChunk(from next: Int, limit: Int) -> Chunk {
        let cs = TextKit.chunks(text, tokens: tokens, from: next, firstMax: limit, max: limit)
        guard cs.count > 1, cs[0].range.count < Self.minSlowChars || cs[1].range.upperBound - cs[0].range.lowerBound <= limit else { return cs[0] }
        return Chunk(range: cs[0].range.lowerBound ..< cs[1].range.upperBound, tokens: cs[0].tokens.lowerBound ..< cs[1].tokens.upperBound)
    }

    /// Playback time queued ahead of the clock, in real seconds at the current rate.
    private var bufferedSeconds: Double { (player.queuedUntil - player.currentTime) / Double(player.rate) }

    /// One slow-engine chunk under the in-flight deadline (PLAN 0.3.0 Sol revision 2b): while it is being made, the
    /// buffered playback left is compared with the fallback's time for this chunk plus 0.3 s; below that the chunk is
    /// abandoned (cancelled, its late result never queued) and nil comes back, so the same chunk is made by the fallback.
    /// An engine failure also returns nil after switching. Nil without a switch means the read moved on (generation).
    private func makeSlow(_ spoken: String, _ engine: SpeechEngine, _ gen: Int) async -> SynthChunk? {
        guard spoken.contains(where: { $0.isLetter || $0.isNumber }) else { return SynthChunk(samples: [], sampleRate: Player.sampleRate, words: []) }
        let box = ResultBox()
        let id = effectiveVoice.id
        let started = Date()
        let work = Task { do { box.value = .success(try await engine.synthesize(spoken, voice: id)) } catch { box.value = .failure(error) } }
        let fallbackTime = 0.2 + fallbackSecondsPerChar * Double(spoken.utf16.count)
        while box.value == nil {
            if gen != generation || Task.isCancelled { work.cancel(); return nil }
            // ponytail: 20 ms polling (the plan's 100 ms deadline check, five times as often); a continuation race if it
            // ever shows in a profile.
            if player.isPlaying, bufferedSeconds < fallbackTime + 0.3 {
                work.cancel()
                Log.write(String(format: "read: abandoned a %d-character chunk in flight, %.2f s buffered", spoken.utf16.count, bufferedSeconds))
                useFallback(keepUpReason)
                return nil
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        switch box.value! {
        case .success(let s):
            let spc = Date().timeIntervalSince(started) / Double(max(spoken.utf16.count, 1))
            slowSecondsPerChar = slowSecondsPerChar.map { 0.5 * $0 + 0.5 * spc } ?? spc
            return s
        case .failure(let error):
            guard gen == generation, !(error is CancellationError) else { return nil }
            Log.write("read: \(id) failed: \(error.localizedDescription)")
            useFallback("Switched to \(fallbackName) because \(effectiveVoice.name) failed")
            return nil
        }
    }

    private var fallbackName: String { (fallback?.engine ?? .system) == .neural ? "Kokoro" : "the system voice" }
    private var keepUpReason: String { "Switched to \(fallbackName) to keep up at \(String(format: "%g", player.rate))×" }

    /// The rest of the read uses the fallback (the system voice when none was given); queued audio and timings stay.
    private func useFallback(_ why: String) {
        let to = fallback ?? Voice(id: "", name: "System", accent: "", gender: "", engine: .system, installed: true, language: voice.language)
        guard effectiveVoice != to else { return }
        effectiveVoice = to
        fallbackReason = why
        Log.write("read: \(why)")
    }

    /// The current engine; a neural failure (bad audio, model error) retries the chunk once with the system voice so
    /// reading never stops silently.
    private func synthesize(_ speakable: String) async throws -> SynthChunk {
        guard speakable.contains(where: { $0.isLetter || $0.isNumber }) else {
            return SynthChunk(samples: [], sampleRate: Player.sampleRate, words: [])   // e.g. a chunk that was only a URL
        }
        let engine = engines.engine(for: effectiveVoice)
        do {
            return try await engine.synthesize(speakable, voice: effectiveVoice.id)
        } catch let error where engine.kind == .neural && !(error is CancellationError) {
            Log.write("read: neural voice failed (\(error.localizedDescription)); retrying the chunk with the system voice")
            return try await engines.system.synthesize(speakable, voice: "")
        }
    }

    private func firstAudio() {
        if !userPaused { startPlayback() }
    }

    /// An output that will not start (no device, engine error) fails the read rather than leaving it "playing" with a
    /// frozen clock; first audio is when sound really starts.
    private func startPlayback() {
        player.play()
        guard player.isPlaying else { return fail("The audio output did not start.") }
        if firstAudioMs == nil, let startedAt { firstAudioMs = Int(Date().timeIntervalSince(startedAt) * 1000) }
        state = .playing
    }

    private func tick() {
        guard state == .playing else { return }
        let t = player.currentTime
        // Zero-length sentinels (removed or unspoken tokens) are never lit; the previous word stays.
        if let i = Timeline.index(at: t, in: timings), timings[i].end > timings[i].start, currentToken != timings[i].token {
            currentToken = timings[i].token
            currentSentence = tokens[timings[i].token].sentence
        }
        if doneEnqueueing, t >= player.queuedUntil - 0.0005 { finish() }
    }

    private func finish() {
        generation += 1
        producer?.cancel()
        ticker?.cancel()
        player.reset()
        state = .finished
    }

    private func fail(_ message: String) {
        generation += 1
        producer?.cancel()
        ticker?.cancel()
        player.reset()
        state = .failed(message)
    }
}

/// The in-flight slow chunk's outcome, written by its task and polled by the watchdog (both on the main actor).
private final class ResultBox { var value: Result<SynthChunk, Error>? }
