// Dictation in more than English (Junior speaks English and French and switches between them). Two candidates behind
// the same DictationASR interface, compared by `--bench --engines parakeet-v3,nemotron`:
// - ParakeetV3Transcriber: Parakeet TDT v3 (25 European languages, no language setting: it writes what it hears). Not a
//   streaming model, so the live preview is the clip so far decoded again about once a second; the final text is one
//   decode of the whole utterance. Same files as the word-timing aligner (`Aligner`), so one download serves both.
// - NemotronTranscriber: Nemotron 3.5 streaming multilingual 0.6B, Latin-script build, "auto" language prompt. Streams like
//   Parakeet Unified, and says which language it heard.
import AVFoundation
import FluidAudio
import TalkReadCore

/// The multilingual recogniser dictation uses (the bench's winner).
@MainActor enum MultilingualRecogniser {
    static func make() -> DictationASR { ParakeetV3Transcriber() }
}

@MainActor final class ParakeetV3Transcriber: DictationASR {
    let directory: URL
    private var manager: AsrManager?
    private(set) var isLoading = false { didSet { onLoadingChange?() } }
    var onLoadingChange: (() -> Void)?
    private var loadError: Error?
    private var loadWaiters: [AsyncStream<Void>.Continuation] = []
    private let queue = RecogniserQueue()

    init(directory: URL? = nil) { self.directory = directory ?? AsrModels.defaultCacheDirectory(for: .v3) }

    var isLoaded: Bool { manager != nil }
    var isDownloaded: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    /// Downloads (first use only; the Settings choice of languages is the consent) and loads; one load shared by every
    /// caller, as `Transcriber.load`.
    func load(progress: ((Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if !isLoading {
            isLoading = true
            let directory = directory
            Task {
                do {
                    if !AsrModels.modelsExist(at: directory, version: .v3) {
                        try await AsrModels.download(to: directory, version: .v3) { p in
                            Task { @MainActor in progress?(p.fractionCompleted * 0.95) }
                        }
                    }
                    let m = AsrManager(config: .default)
                    try await m.loadModels(try await AsrModels.load(from: directory, version: .v3))
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
        for await _ in done {}
        try Task.checkCancellation()
        guard manager != nil else { throw loadError ?? ASRError.notInitialized }
        progress?(1)
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
            var samples: [Float] = []
            let preview = Preview()
            for await buffer in audio {
                try Task.checkCancellation()
                if let data = buffer.floatChannelData?[0] { samples += UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)) }
                // A preview once there is a second more audio than the last one had and that one has finished; longer
                // clips preview less often, so the cost of decoding everything again stays about level.
                if !preview.busy, samples.count >= 16_000, samples.count - preview.at >= max(16_000, samples.count / 8) {
                    preview.busy = true
                    preview.at = samples.count
                    let clip = samples
                    preview.task = Task { @MainActor in
                        if let text = try? await Self.decode(m, clip).text, !Task.isCancelled { partial(text) }
                        preview.busy = false
                    }
                }
            }
            preview.task?.cancel()
            await preview.task?.value                      // the manager decodes one clip at a time
            try Task.checkCancellation()
            if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
            let result = try await Self.decode(m, samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = Paragraphs.words(from: (result.tokenTimings ?? []).map {
                .init(text: $0.token, start: $0.startTime, end: $0.endTime + Transcriber.endLag)
            })
            return Transcript(text: text, pauses: Paragraphs.pauses(text: text, words: words))
        }
    }

    /// One whole-clip decode. The `.english` hint only keeps the decoder in the Latin script (FluidAudio's token
    /// language filter, against Cyrillic slips); it does not choose the language, so French comes out as French.
    private static func decode(_ m: AsrManager, _ samples: [Float]) async throws -> ASRResult {
        var state = try TdtDecoderState(decoderLayers: await m.decoderLayerCount)
        return try await m.transcribe(samples, decoderState: &state, language: .english)
    }

    @MainActor private final class Preview {
        var busy = false
        var at = 0
        var task: Task<Void, Never>?
    }
}

@MainActor final class NemotronTranscriber: DictationASR {
    /// 560 ms: the shortest tier, nearest Parakeet Unified's 640 ms for the live text. Its known fault (punctuation
    /// thinning out over minutes of unbroken speech) does not reach dictation, which starts afresh every utterance.
    let chunkMs: Int
    /// ISO 639-1 codes. One language sets the model's prompt to it; more than one leaves it on "auto".
    var languages: [String] = ["en", "fr"]
    private var manager: StreamingNemotronMultilingualAsrManager?
    private(set) var isLoading = false { didSet { onLoadingChange?() } }
    var onLoadingChange: (() -> Void)?
    private var loadError: Error?
    private var loadWaiters: [AsyncStream<Void>.Continuation] = []
    private let queue = RecogniserQueue()
    /// The language the model said it heard in the last utterance ("fr-FR"), nil when it said none.
    private(set) var lastLanguage: String?

    init(chunkMs: Int = 560) { self.chunkMs = chunkMs }

    var isLoaded: Bool { manager != nil }
    var isDownloaded: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(Repo.nemotronMultilingual.folderName)/latin/\(chunkMs)ms")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata).path)
    }

    func load(progress: ((Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if !isLoading {
            isLoading = true
            let chunkMs = chunkMs
            Task {
                do {
                    // "en" picks the Latin-script build (en, es, fr, it, pt, de); the prompt is set per utterance.
                    let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                        languageCode: "en", chunkMs: chunkMs) { p in Task { @MainActor in progress?(p.fractionCompleted * 0.95) } }
                    let m = StreamingNemotronMultilingualAsrManager()
                    try await m.loadFromShared(shared)
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
        for await _ in done {}
        try Task.checkCancellation()
        guard manager != nil else { throw loadError ?? ASRError.notInitialized }
        progress?(1)
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
            await m.reset()
            await m.setLanguage(languages.count == 1 ? languages[0] : "auto")
            await m.setPartialCallback { text in Task { @MainActor in partial(text) } }
            var frames = 0
            for await buffer in audio {
                try Task.checkCancellation()
                frames += Int(buffer.frameLength)
                _ = try await m.process(audioBuffer: buffer)
            }
            try Task.checkCancellation()
            if frames < 16_000 { _ = try await m.process(audioBuffer: Transcriber.buffer(ArraySlice(repeating: 0, count: 16_000 - frames))) }
            let (said, timings) = try await m.finishWithTokenTimings()
            lastLanguage = await m.detectedLanguage()
            await m.setPartialCallback { _ in }
            let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcript(text: text, pauses: Paragraphs.pauses(text: text, words: Paragraphs.words(from: timings.map {
                .init(text: $0.token, start: $0.startTime, end: $0.endTime + Transcriber.endLag)
            })), language: lastLanguage.map { String($0.prefix(2)).lowercased() })
        }
    }
}
