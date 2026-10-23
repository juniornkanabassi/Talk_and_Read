// One read: chunks -> synthesis ahead of playback -> player -> timeline -> highlight ticks.
// A producer task synthesises up to three chunks ahead; a 30 Hz main-actor tick maps the player's media clock to the
// current token. Seek, skip and voice change restart synthesis at a token (PLAN decision 15); rate is instant.
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
    /// Media-time timings of every chunk queued since the last (re)start, in order.
    private(set) var timings: [TalkReadCore.WordTiming] = []

    private let engines: Engines
    private let lexicon: [String: String]
    private let startToken: Int
    private var producer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var chunkEnds: [Double] = []
    private var doneEnqueueing = false
    private var userPaused = false
    private var needsRestart = false
    private var generation = 0
    private var startedAt: Date?

    /// `fallback`: the Kokoro voice of the same language the read switches to if `voice`'s engine cannot keep up (V3).
    init(text: String, capture: Capture?, voice: Voice, rate: Float, startToken: Int, engines: Engines, lexicon: [String: String], fallback: Voice? = nil) {
        self.text = text
        self.tokens = TextKit.tokenize(text)
        self.capture = capture
        self.voice = voice
        self.engines = engines
        self.lexicon = lexicon
        self.startToken = startToken
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

    private func produce(_ chunks: [Chunk], _ gen: Int) async {
        for (k, chunk) in chunks.enumerated() {
            // ponytail: polls the clock every 50 ms to keep at most three chunks queued; a completion-driven wait if
            // 50 ms ever matters (chunks are seconds long).
            while gen == generation, chunkEnds.filter({ $0 > player.currentTime }).count >= 3 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard gen == generation, !Task.isCancelled else { return }
            let speakable = Speakable.make(text, range: chunk.range, lexicon: lexicon)
            let synth: SynthChunk
            do {
                synth = try await synthesize(speakable.text)
            } catch {
                guard gen == generation else { return }
                Log.write("read: chunk \(k) failed: \(error.localizedDescription)")
                return fail(error.localizedDescription)
            }
            guard gen == generation, !Task.isCancelled else { return }
            let start = player.enqueue(synth)
            chunkEnds.append(player.queuedUntil)
            timings += Timeline.timings(chunkTokens: Array(tokens[chunk.tokens]), chunkTokenOffset: chunk.tokens.lowerBound,
                                        speakable: speakable, spoken: synth.words, offset: start,
                                        chunkDuration: player.queuedUntil - start)
            if k == 0 { firstAudio() }
        }
        doneEnqueueing = true
        player.moreComing = false
    }

    /// The chosen engine; a neural failure (bad audio, model error) retries the chunk once with the system voice so
    /// reading never stops silently.
    private func synthesize(_ speakable: String) async throws -> SynthChunk {
        guard speakable.contains(where: { $0.isLetter || $0.isNumber }) else {
            return SynthChunk(samples: [], sampleRate: Player.sampleRate, words: [])   // e.g. a chunk that was only a URL
        }
        let engine = engines.engine(for: voice)
        do {
            return try await engine.synthesize(speakable, voice: voice.id)
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
