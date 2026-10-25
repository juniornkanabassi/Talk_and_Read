// One read: chunks -> synthesis ahead of playback -> player -> timeline -> highlight ticks.
// A producer task synthesises up to three chunks ahead; a 30 Hz main-actor tick maps the player's media clock to the
// current token. Seek, skip and voice change restart synthesis at a token (PLAN decision 15); rate is instant.
// Slow engines (Qwen3, Breeze) get bounded chunks sized by a time budget and a watchdog on the chunk in flight; when they
// cannot keep up, the rest of the read goes to the warm Kokoro fallback without restarting speech (PLAN 0.3.0, Sol
// revisions 2, 2b and 4). Kokoro-only reads take exactly the 1.0 path.
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
    /// The speed the user chose. The Player stretches by `rate / nativeSpeed`.
    private(set) var rate: Float
    /// How fast an engine that `speaksFaster` (Kokoro) speaks the chunks queued since the last restart; 1 for the others.
    private(set) var nativeSpeed: Float = 1
    private(set) var voice: Voice
    /// The voice actually speaking now: `voice`, or the Kokoro fallback once the engine fell behind (V3). The UI shows it.
    @Published private(set) var effectiveVoice: Voice
    /// Why the read switched to the fallback voice, shown in the player until the read ends; nil otherwise.
    @Published private(set) var fallbackReason: String?
    /// Media-time timings of every chunk queued since the last (re)start, in order.
    private(set) var timings: [TalkReadCore.WordTiming] = []
    /// Which voice made each chunk queued since the last (re)start (self-test evidence).
    private(set) var made: [(tokens: Range<Int>, voice: String)] = []

    /// Slow-engine chunk sizes in UTF-16 characters: the opening chunk (see `openingChars(rate:)`), then at most
    /// `slowChars`; a chunk the budget cannot fit to `minSlowChars` goes to the fallback.
    static let slowChars = 160, minSlowChars = 25
    /// Media seconds a slow engine may run ahead of the clock (about three full 160-character chunks).
    static let slowAhead = 30.0
    /// The opening chunk is all the buffer the next chunk can be made in, so it grows with the rate: about 30 characters
    /// per 1x (about 2 s of playback), filled to that size across sentences. Smaller openings left the read handing over
    /// at its second chunk even at 2x (Qwen3, 23 Oct). The price is first audio: measured 0.9-1.3 s at 2x in French,
    /// 1.8 s in English, 1.4-2.4 s at 2.5x (target 1.5 s); a fixed 60 brings 2.5x back to about 1.5 s but then Qwen3
    /// mostly hands over to Kokoro within seconds at 2.5x. Breeze caps it at 45: rendering at about 2.2x real time it
    /// cannot keep up above about 1.5x, where a bigger opening only delays first audio (about 3 s for a 60-character
    /// sentence) before the hand-over; at 1.5x and below the rule gives 45 or less anyway.
    static func openingChars(rate: Float, kind: EngineKind = .qwen) -> Int { min(max(40, Int(30 * rate)), kind == .breeze ? 45 : slowChars) }
    // ponytail: a slow engine's fixed cost per chunk (prefill, decoder start, alignment), fitted through the session as
    // fixed seconds + seconds per second of audio: Qwen3 0.18 s + 0.27 s/s (23 Oct, 148 chunks); Breeze 0.30 s + 0.41 s/s
    // (23 Oct, 119 chunks of 26-172 characters, both voices, M3 Max on mains power), 0.24 s of it the prefill, of which
    // re-encoding the 13 s reference clip is 0.04 s (so no reference cache, PLAN 0.4.0 Sol rev. 2).
    // The budget charges it once per chunk so small chunks are not mistaken for a slow engine.
    static func chunkOverhead(_ kind: EngineKind) -> Double { kind == .breeze ? 0.30 : 0.18 }
    // ponytail: Breeze's cost per character swings with what it says (0.05-0.15 s of audio per character; numbers, dates
    // and pauses take longest), so the budget charges it at its 95th-percentile overrun: actual over predicted, 125 chunks
    // (23 Oct), median 0.96, p90 1.19, p95 1.25, max 1.47. Charged as measured, overruns tripped the watchdog's 0.25 s
    // margin even at 1.5x. Qwen3's steadier cost is charged as measured.
    static func costMargin(_ kind: EngineKind) -> Double { kind == .breeze ? 1.25 : 1 }
    /// Buffered playback a slow chunk must leave when ready, on top of the fallback's per-character time for it: the
    /// watchdog's deadline is 0.5 s of it (the fallback's fixed 0.2 s plus 0.3 s), the rest is the margin before that
    /// deadline. Measured 23 Oct with Qwen3 on the M3 Max, 60 s reads: 0.5 (finishing on the deadline itself) let
    /// ordinary chunk-to-chunk variance trip the watchdog even at 2x; 1.0 kept up at 2x but could not grow past the
    /// opening chunk at 2.5x; 0.75 kept up at both, with no starvation.
    static let spare = 0.75
    // ponytail: the fallback's fixed time while it is not loaded (Sol inspection 4 #2), used in place of its warm 0.2 s.
    // Kokoro's reload after an unload measured 0.8-1.0 s on the M3 Max (23 Oct, English and French, load plus its
    // warm-up phrase), rounded up; measure per engine if another fallback is added.
    static let fallbackColdLoad = 1.5

    private let engines: Engines
    private let lexicon: [String: String]
    /// Source ranges never spoken (a PDF's running headers and footers), and whether citation marks are dropped.
    private let skip: [Range<Int>]
    private let skipCitations: Bool
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
    /// Measured seconds of work per spoken (speakable) character: the slow engine's (synthesis plus alignment, beyond
    /// `chunkOverhead`) and the fallback's. Spoken characters, because the engine pays for what it hears.
    private var slowSecondsPerChar: Double?
    // ponytail: seeded from the R2 run of 23 Oct (Kokoro .legacy, M3 Max: 6.4 s of work for about 2,000 spoken
    // characters, first chunk 0.2 s), rounded up; replaced by measurement once the fallback speaks.
    private var fallbackSecondsPerChar = 0.004
    /// `engines.unloads` when the fallback last finished preparing: it is warm only while nothing has unloaded since.
    private var fallbackPreparedAt: Int?
    private var fallbackWarming: Date?
    /// Whether this (re)start has queued real sound yet; a silent chunk (a skipped running head) does not count.
    private var heardAudio = false

    /// `fallback`: the Kokoro voice of the same language the read switches to if `voice`'s engine cannot keep up (V3).
    init(text: String, capture: Capture?, voice: Voice, rate: Float, startToken: Int, engines: Engines, lexicon: [String: String], fallback: Voice? = nil,
         skip: [Range<Int>] = [], skipCitations: Bool = false) {
        self.text = text
        self.tokens = TextKit.tokenize(text)
        self.capture = capture
        self.voice = voice
        self.effectiveVoice = voice
        self.engines = engines
        self.lexicon = lexicon
        self.skip = skip.sorted { $0.lowerBound < $1.lowerBound }
        self.skipCitations = skipCitations
        self.startToken = startToken
        self.fallback = fallback
        self.rate = rate
        player.rate = rate
        player.onInterrupted = { [weak self] in
            // Device change, paused or not: the player dropped its queue, so the producer and its bookkeeping are stale.
            // Stop them; resume restarts synthesis at the word that was playing.
            guard let self, [State.playing, .preparing, .paused].contains(self.state) else { return }
            self.generation += 1
            self.producer?.cancel()
            self.ticker?.cancel()
            self.needsRestart = true
            self.userPaused = true
            self.state = .paused
        }
    }

    func start() {
        startedAt = Date()
        warmFallback()
        restart(from: startToken)
        // Queued behind the producer, so the engine starts while the first chunk is synthesised off the main actor;
        // skipped when the read already finished (nothing speakable) or was paused (nothing would stop the engine).
        Task { [weak self] in if let self, state == .preparing { player.warmUp() } }
    }

    func pause() {
        guard state == .playing || state == .preparing else { return }
        userPaused = true
        player.pause()
        ticker?.cancel()   // nothing to tick while paused; startPlayback starts it again
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        userPaused = false
        warmFallback()   // a long pause may have let the idle timer unload it
        if needsRestart {
            restart(from: currentToken ?? startToken)
        } else if !heardAudio {
            state = .preparing   // first audible chunk still synthesising (a silent one may be queued); it starts playing when queued
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
        // Clamped first: any Int arrives from the CLI or socket and must not overflow.
        let n = min(max(sentences, -last.sentence - 1), last.sentence + 1), step = n < 0 ? -1 : 1
        // Sentences with nothing to say (skipped furniture, a lone "[citation needed]") are stepped over, judged as
        // playback judges them, so Previous reaches the last sentence actually read. Only the sentences passed are checked.
        func audible(_ s: Int) -> Bool {
            func firstToken(from s: Int) -> Int {   // tokens are in sentence order
                var l = 0, h = tokens.count
                while l < h { let m = (l + h) / 2; if tokens[m].sentence >= s { h = m } else { l = m + 1 } }
                return l
            }
            let a = firstToken(from: s), b = firstToken(from: s + 1)
            guard a < b else { return false }
            // From the previous token's end to the next sentence's first token, so the brackets and punctuation around
            // the words are judged too ("[citation needed]" alone is silent, as in playback).
            let lo = a == 0 ? 0 : tokens[a - 1].range.upperBound, hi = b < tokens.count ? tokens[b].range.lowerBound : text.utf16.count
            return Speakable.make(text, range: lo..<hi, lexicon: lexicon,
                                  language: voice.language, skip: skip, skipCitations: skipCitations).text
                .contains { $0.isLetter || $0.isNumber }
        }
        var target = current
        for _ in 0..<abs(n) {
            var c = target + step
            while c >= 0, c <= last.sentence, !audible(c) { c += step }
            guard c >= 0, c <= last.sentence else { break }
            target = c
        }
        // Next with nothing audible left (only furniture or annotations after this sentence): the read is over.
        if n > 0, target == current { return finish() }
        if let first = tokens.firstIndex(where: { $0.sentence >= target }) { restart(from: first) }
    }

    func seek(token: Int) {
        guard tokens.indices.contains(token) else { return }
        restart(from: token)
    }

    /// Instant while the engine's own speed stays; past `Settings.stretchLimit` with Kokoro the speed it speaks at changes,
    /// so the read restarts at the word playing (audio already made is at the old pace).
    func setRate(_ r: Float) {
        rate = r
        let native = speakingSpeed(for: effectiveVoice)
        guard native != nativeSpeed, state != .finished, !tokens.isEmpty else { return player.rate = r / nativeSpeed }
        restart(from: currentToken ?? startToken)
    }

    private func speakingSpeed(for v: Voice) -> Float { engines.engine(for: v).speaksFaster ? TalkReadCore.Settings.nativeSpeed(for: rate) : 1 }

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
        // Above the speed the chosen engine sustains (Breeze, 1.5x) the read goes on with the fallback (warm Kokoro, else
        // the system voice of its language): at start (its first audio, no wait for a chunk handed over seconds later,
        // no GPU; lead, 0.4.0) and at every restart (seek, skip, resume after an interruption) once the rate is past it
        // (Sol inspection 5 #3, #4). The saved choice is untouched; a fallback already chosen stays, as any hand-over.
        if effectiveVoice == voice, let limit = engines.engine(for: voice).keepsUpTo, rate > limit {
            useFallback("\(voice.engine.modelName) keeps up to \(String(format: "%g", limit))×; \(fallbackName) is reading at \(String(format: "%g", rate))×")
        }
        // A hand-over to Kokoro after this keeps 1: the slow engine's chunks already queued are at its natural pace.
        nativeSpeed = speakingSpeed(for: effectiveVoice)
        player.rate = rate / nativeSpeed
        timings = []
        made = []
        chunkEnds = []
        heardAudio = false
        doneEnqueueing = false
        needsRestart = false
        if case .failed = state { userPaused = false }
        let chunks = TextKit.chunks(text, tokens: tokens, from: token)
        guard !chunks.isEmpty else { return finish() }
        state = userPaused ? .paused : .preparing
        player.moreComing = true
        producer = Task { [weak self] in await self?.produce(chunks, gen) }
    }

    /// The 30 Hz clock-to-token tick runs only while playing (efficiency fix 6: a paused read woke 30 times a second).
    private func startTicker() {
        guard ticker == nil || ticker!.isCancelled else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(nanoseconds: 33_000_000)
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
            // ponytail: polls the clock every 50 ms (500 ms while paused, when nothing drains) to keep at most three chunks
            // queued (a slow engine: `slowAhead` seconds, since its early chunks are small and three of them would stop the
            // buffer growing); a completion-driven wait if 50 ms ever matters (chunks are seconds long).
            while gen == generation, engines.engine(for: effectiveVoice).isSlow ? player.queuedUntil - player.currentTime >= Self.slowAhead
                    : chunkEnds.filter({ $0 > player.currentTime }).count >= 3 {
                try? await Task.sleep(nanoseconds: state == .paused ? 500_000_000 : 50_000_000)
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
            made.append((chunk.tokens, effectiveVoice.id))
            timings += Timeline.timings(chunkTokens: Array(tokens[chunk.tokens]), chunkTokenOffset: chunk.tokens.lowerBound,
                                        speakable: said, spoken: synth.words, offset: start,
                                        chunkDuration: player.queuedUntil - start, language: voice.language)
            next = chunk.tokens.upperBound
            // A chunk with nothing to say (a skipped running head, a lone URL) keeps its zero-length timings but is not
            // the opening chunk: playback, first audio and the slow engine's opening budget wait for real sound.
            guard !synth.samples.isEmpty else {   // and not in chunkEnds: a silent chunk is no audio ahead
                // Still opening: recut from the next token so the first audible chunk is the short one and first audio stays fast.
                if k == 0 { plan = TextKit.chunks(text, tokens: tokens, from: next)[...] }
                continue
            }
            chunkEnds.append(player.queuedUntil)
            heardAudio = true
            if k == 0 { firstAudio() }
            k += 1
        }
        if k == 0 { return finish() }   // nothing audible from here on: the read is over, without opening the output
        doneEnqueueing = true
        player.moreComing = false
    }

    private func speakable(_ c: Chunk) -> Speakable {
        Speakable.make(text, range: c.range, lexicon: lexicon, language: voice.language, skip: skip, skipCitations: skipCitations)
    }

    /// The next slow chunk under the time budget (PLAN 0.3.0 Sol revision 2): the largest one (at most `slowChars`) whose
    /// measured cost leaves at least `spare` plus the fallback's per-character time for it buffered at the current rate.
    /// Nil when not even a `minSlowChars` chunk fits: that chunk and the rest go to the fallback. Chunks thus grow only
    /// as fast as the engine's measured headroom allows.
    private func nextSlowChunk(from next: Int, opening: Bool) -> Chunk? {
        let kind = engines.engine(for: effectiveVoice).kind
        if opening { return slowChunk(from: next, limit: Self.openingChars(rate: rate, kind: kind), fill: 10) }   // the buffer: fill it
        // Paused (nothing drains) or nothing measured yet: the largest chunk; the watchdog covers a later resume.
        guard player.isPlaying, let spc = slowSecondsPerChar else { return slowChunk(from: next, limit: Self.slowChars) }
        let fixed = Self.spare + fallbackFixed - 0.2   // `spare` counts the warm fallback's 0.2 s
        let room = (bufferedSeconds - fixed - Self.chunkOverhead(kind)) / (spc * Self.costMargin(kind) + fallbackSecondsPerChar)   // spoken characters that fit
        var limit = min(Int(room), Self.slowChars)
        // ponytail: each try re-chunks the rest of the text (linear in it, about 1 ms per 10k characters); a token
        // window if 100k-character reads ever show it.
        while limit >= Self.minSlowChars {
            let c = slowChunk(from: next, limit: limit)
            let n = speakable(c).text.utf16.count
            if Double(n) <= room { return c }
            limit = min(limit - 1, Int(Double(limit) * room / Double(n)))   // shrink by the overshoot
        }
        Log.write(String(format: "read: budget %.2f s buffered at %gx, %.4f s per character, room %.0f characters",
                         bufferedSeconds, player.rate, spc * Self.costMargin(kind) + fallbackSecondsPerChar, room))
        return nil
    }

    /// About `limit` characters from `next`: the rest of the current sentence, then the next ones while at least `fill`
    /// characters of room are left (the opening chunk fills from 10), the last cut by TextKit's rule (clause mark, else
    /// space); never under `minSlowChars` in all. A sentence that overruns the room by less than `minSlowChars` is taken
    /// whole, so a cut never leaves a sliver ("2027." alone costs a chunk's fixed overhead for one word).
    private func slowChunk(from next: Int, limit: Int, fill: Int = minSlowChars) -> Chunk {
        var range = 0 ..< 0, end = next
        repeat {
            let room = max(limit - range.count, Self.minSlowChars)
            var c = TextKit.chunks(text, tokens: tokens, from: end, firstMax: room + Self.minSlowChars, max: room)[0]
            if c.tokens.upperBound < tokens.count, tokens[c.tokens.upperBound].sentence == tokens[c.tokens.upperBound - 1].sentence {
                c = TextKit.chunks(text, tokens: tokens, from: end, firstMax: room, max: room)[0]   // longer still: cut at the room
            }
            range = (end == next ? c.range.lowerBound : range.lowerBound) ..< c.range.upperBound
            end = c.tokens.upperBound
        } while end < tokens.count && (limit - range.count >= fill || range.count < Self.minSlowChars)
        return Chunk(range: range, tokens: next ..< end)
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
        while box.value == nil {
            if gen != generation || Task.isCancelled { work.cancel(); return nil }
            // ponytail: 20 ms polling (the plan's 100 ms deadline check, five times as often); a continuation race if it
            // ever shows in a profile. The fallback's time is re-read each pass: it drops once its warm-up finishes.
            if player.isPlaying, bufferedSeconds < fallbackFixed + fallbackSecondsPerChar * Double(spoken.utf16.count) + 0.3 {
                work.cancel()
                Log.write(String(format: "read: abandoned a %d-character chunk in flight, %.2f s buffered", spoken.utf16.count, bufferedSeconds))
                useFallback(keepUpReason)
                return nil
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        switch box.value! {
        case .success(let s):
            let spc = max(Date().timeIntervalSince(started) - Self.chunkOverhead(engine.kind), 0) / Double(max(spoken.utf16.count, 1))
            slowSecondsPerChar = slowSecondsPerChar.map { 0.5 * $0 + 0.5 * spc } ?? spc
            return s
        case .failure(let error):
            guard gen == generation, !(error is CancellationError) else { return nil }
            Log.write("read: \(id) failed: \(error.localizedDescription)")
            useFallback("Switched to \(fallbackName) because \(effectiveVoice.name) failed")
            return nil
        }
    }

    /// Prepares the fallback of a slow-engine read unless it is still warm (at start, and on resume after a long pause),
    /// so a switch costs one Kokoro chunk, not a model load.
    private func warmFallback() {
        guard let fallback, engines.engine(for: voice).isSlow, fallbackPreparedAt != engines.unloads, fallbackWarming == nil else { return }
        let engine = engines.engine(for: fallback), unloads = engines.unloads
        fallbackWarming = Date()
        Task {
            defer { fallbackWarming = nil }
            do {
                try await engine.prepare(voice: fallback.id)
                if engines.unloads == unloads { fallbackPreparedAt = unloads }   // an unload during the load undoes it
            } catch { Log.write("read: fallback warm-up failed: \(error)") }
        }
    }

    /// The fallback's fixed time for a chunk: 0.2 s once prepared since the last unload (the system voice needs none),
    /// else what is left of its load since the warm-up began (all of it when none is running), and never the warm 0.2 s
    /// until the warm-up has really finished (Sol verification 5, #2): a slow reload keeps 0.5 s in reserve, so the
    /// hand-over comes earlier rather than late.
    // ponytail: the 0.5 s floor is a guess for a reload slower than `fallbackColdLoad`; first-launch loads (8-14 s) that
    // coincide with a hand-over would need the warm-up's own progress.
    private var fallbackFixed: Double {
        guard fallback != nil, fallbackPreparedAt != engines.unloads else { return 0.2 }
        return max(0.5, Self.fallbackColdLoad - (fallbackWarming.map { Date().timeIntervalSince($0) } ?? 0))
    }

    private var fallbackName: String { (fallback?.engine ?? .system) == .neural ? "Kokoro" : "the system voice" }
    private var keepUpReason: String { "Switched to \(fallbackName) to keep up at \(String(format: "%g", rate))×" }

    /// The rest of the read uses the fallback (the system voice of the read's language when none was given); queued
    /// audio and timings stay.
    private func useFallback(_ why: String) {
        let to = fallback ?? systemVoice
        guard effectiveVoice != to else { return }
        effectiveVoice = to
        fallbackReason = why
        Log.write("read: \(why)")
    }

    /// The current engine; a neural failure (bad audio, model error) retries the chunk once with the system voice of the
    /// read's language so reading never stops silently.
    private func synthesize(_ speakable: String) async throws -> SynthChunk {
        guard speakable.contains(where: { $0.isLetter || $0.isNumber }) else {
            return SynthChunk(samples: [], sampleRate: Player.sampleRate, words: [])   // e.g. a chunk that was only a URL
        }
        let engine = engines.engine(for: effectiveVoice)
        do {
            return try await engine.synthesize(speakable, voice: effectiveVoice.id, speed: nativeSpeed)
        } catch let error where engine.kind == .neural && !(error is CancellationError) {
            let retry = systemVoice
            Log.write("read: neural voice failed (\(error.localizedDescription)); retrying the chunk with \(retry.name)")
            return try await engines.system.synthesize(speakable, voice: retry.id)
        }
    }

    /// The installed system voice of the read's language (French stays French, Sol inspection 4 #3); "" (the best English
    /// voice) only if that language has none.
    private var systemVoice: Voice {
        SystemEngine.voice(language: voice.language) ?? Voice(id: "", name: "System", accent: "", gender: "", engine: .system, installed: true, language: voice.language)
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
        startTicker()
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
