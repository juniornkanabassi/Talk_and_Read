// FluidAudio Parakeet Unified 0.6B streaming recogniser (640 ms tier, int8; PLAN decision 4): warm model, one utterance
// at a time, live partials, and file transcription through the same path.
import AVFoundation
import FluidAudio
import TalkReadCore

/// What a recogniser returns: the text, and the silence before each of its sentences when it knows (Parakeet, unknown
/// entries nil; Apple's recogniser has none). The streaming partials stay plain text.
struct Transcript: Sendable {
    var text: String
    var pauses: [Double?] = []
}

/// What the dictation controller needs from a recogniser (the real `Transcriber`, or a fake in the self-test).
@MainActor protocol DictationASR: AnyObject {
    /// Transcribes one utterance: every buffer of `audio` (16 kHz mono Float32) until the stream finishes.
    func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> Transcript
    /// Downloads and loads the model once; a cancelled caller stops waiting at once while the load carries on.
    func load(progress: ((Double) -> Void)?) async throws
    /// Frees the model. False, freeing nothing, while it is in use or loading; true once nothing is resident (Sol #24).
    @discardableResult func unload() -> Bool
    var isLoaded: Bool { get }
    /// The model is downloading or loading; stays true until that ends, even after every caller stopped waiting.
    var isLoading: Bool { get }
    /// Called on the main actor whenever `isLoading` changes.
    var onLoadingChange: (() -> Void)? { get set }
    /// The model is on this Mac, so a load needs no download.
    var isDownloaded: Bool { get }
}

extension DictationASR {
    var isDownloaded: Bool { true }

    /// Whole-clip transcription (dictate-file, self-test): fed in 1 s buffers, then finished.
    func transcribe(samples: [Float]) async throws -> Transcript {
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            feed.yield(Transcriber.buffer(samples[start..<min(start + 16_000, samples.count)]))
        }
        feed.finish()
        return try await run(stream, partial: { _ in })
    }
}

/// One recognition at a time, first come first served: the recogniser is reset per utterance and its state cannot be
/// shared. Work cancelled before or while it waited never enters (Sol #23). The self-test's fake recogniser uses it too.
@MainActor final class RecogniserQueue {
    private(set) var inUse = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if inUse { await withCheckedContinuation { waiting.append($0) } }
        inUse = true
        defer { if waiting.isEmpty { inUse = false } else { waiting.removeFirst().resume() } }   // hand over, still in use
        try Task.checkCancellation()
        return try await body()
    }
}

@MainActor final class Transcriber: DictationASR {
    static let variant = StreamingModelVariant.parakeetUnified640ms
    private var manager: StreamingUnifiedAsrManager?
    private(set) var isLoading = false { didSet { onLoadingChange?() } }
    var onLoadingChange: (() -> Void)?
    private var loadError: Error?
    private var loadWaiters: [AsyncStream<Void>.Continuation] = []
    private let queue = RecogniserQueue()
    /// Terms the recogniser listens for (CTC keyword boosting with Parakeet CTC 110M); nil switches boosting off. Read at
    /// load, so a change needs an unload.
    var boosting: CustomVocabularyContext?

    var isLoaded: Bool { manager != nil }
    var isDownloaded: Bool { Self.isDownloaded }

    /// The model files are already in FluidAudio's cache (no download needed).
    static var isDownloaded: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(Repo.parakeetUnified.folderName)")
        let names = ModelNames.ParakeetUnified.self
        let encoder = names.streamingEncoderFile(precision: .int8, contextSuffix: variant.unifiedConfig!.contextSuffix)
        return [encoder, names.decoderFile, names.jointDecisionFile, names.vocab]
            .allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Downloads (huggingface.co, first use only) and loads the model; later calls return at once. One load, shared by
    /// every caller, runs to the end even when its callers are cancelled (`isLoading` until then), so the idle unload
    /// sees it (Sol #24) and a cancelled caller is not held up by it (Sol #23).
    func load(progress: ((Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if !isLoading {
            isLoading = true
            Task {
                do {
                    let m = StreamingUnifiedAsrManager(config: Self.variant.unifiedConfig!, encoderPrecision: .int8)
                    try await m.loadModels(to: nil, configuration: nil) { p in
                        Task { @MainActor in progress?(p.fractionCompleted) }
                    }
                    if let boosting {
                        try await m.configureVocabularyBoosting(vocabulary: boosting, ctcModels: try await CtcModels.downloadAndLoad())
                    }
                    manager = m
                    loadError = nil
                } catch {
                    loadError = error
                }
                isLoading = false
                for waiter in loadWaiters { waiter.finish() }
                loadWaiters = []
            }
        }
        let (done, waiter) = AsyncStream.makeStream(of: Void.self)
        loadWaiters.append(waiter)
        for await _ in done {}                    // ends when the load does, or at once when this task is cancelled
        try Task.checkCancellation()
        guard manager != nil else { throw loadError ?? ASRError.notInitialized }
    }

    @discardableResult func unload() -> Bool {
        guard !queue.inUse, !isLoading else { return false }
        if let m = manager {
            manager = nil
            Task { await m.cleanup() }
        }
        return true
    }

    func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> Transcript {
        try await queue.exclusive {
            try await load()
            guard let m = manager else { throw ASRError.notInitialized }
            try await m.reset()
            await m.setPartialTranscriptCallback { text in Task { @MainActor in partial(text) } }
            var frames = 0
            var tokens: [TokenTiming] = []                    // kept whole: a word can span two drains
            for await buffer in audio {
                try Task.checkCancellation()
                try await m.appendAudio(buffer)
                frames += Int(buffer.frameLength)
                try await m.processBufferedAudio()
                tokens += await m.consumeTokenTimings()
            }
            try Task.checkCancellation()
            if frames < 16_000 { try await m.appendAudio(Self.buffer(ArraySlice(repeating: 0, count: 16_000 - frames))) }
            let said = try await m.finish()
            tokens += await m.consumeTokenTimings()
            await m.setPartialTranscriptCallback { _ in }
            let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcript(text: text, pauses: Paragraphs.pauses(text: text, words: Paragraphs.words(from: tokens.map {
                .init(text: $0.token, start: $0.startTime, end: $0.endTime + Self.endLag)
            })))
        }
    }

    /// The boosting terms for a vocabulary: each written form once, its heard forms as aliases.
    static func boostingTerms(_ vocabulary: [String: String]) -> CustomVocabularyContext? {
        let heard = Dictionary(grouping: vocabulary.keys, by: { vocabulary[$0]! })
        let terms = heard.keys.sorted().map { written in
            CustomVocabularyTerm(text: written, aliases: heard[written]!.filter { $0.caseInsensitiveCompare(written) != .orderedSame }.sorted())
        }
        return terms.isEmpty ? nil : CustomVocabularyContext(terms: terms)
    }

    /// The model times a word's end early and the next word's start late, so every gap reads long: Kokoro speech with known
    /// gaps (24 Oct; 0.4 s inside a paragraph, 1.2 s between) read 0.25 to 0.55 s longer. Word ends are moved on by this much.
    // ponytail: calibrated on synthetic speech only; re-measure on Junior's own dictation before trusting the 1 s threshold.
    nonisolated static let endLag = 0.3

    nonisolated static func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: StreamConverter.format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { b.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return b
    }

    /// 16 kHz mono samples from any audio file AVFoundation can read (WAV, M4A, ...).
    nonisolated static func samples(of file: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(file)
    }
}
