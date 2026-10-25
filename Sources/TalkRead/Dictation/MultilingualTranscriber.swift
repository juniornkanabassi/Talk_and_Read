// Dictation in more than English (Junior speaks English and French and switches mid-sentence): Parakeet TDT v3, 25
// European languages and no language setting, so it writes what it hears in the language it hears. Not a streaming
// model: the live text is the clip so far decoded again about once a second, the final text one decode of the whole
// utterance. Same files as the word-timing aligner (`Aligner`), so one download serves both.
// Bench on the Mac, 25 Oct (28 English clips, 12 French, 12 switching mid-utterance; the French ones synthetic): WER
// 5.7 % / 2.2 % / 5.9 % against Parakeet Unified's 6.7 % / 83 % / 45 %, about 50 ms more from release to text, no
// extra memory. Nemotron 3.5 streaming multilingual scored 16 to 17 % in all three and needed 1.8 GB, so it was dropped.
import AVFoundation
import FluidAudio
import TalkReadCore

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
            // Every way out of the loop (a cancel included) ends the preview first: it decodes on the same manager, so it
            // must be over before this utterance gives up the queue or an idle unload frees the model.
            @MainActor func endPreview() async {
                preview.stopped = true
                preview.task?.cancel()
                await preview.task?.value
            }
            do {
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
                            if let text = try? await Self.decode(m, clip).text, !Task.isCancelled, !preview.stopped { partial(text) }
                            preview.busy = false
                        }
                    }
                }
                try Task.checkCancellation()
            } catch {
                await endPreview()
                throw error
            }
            await endPreview()
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
        /// The utterance has moved on: a decode that finishes now shows nothing.
        var stopped = false
        var at = 0
        var task: Task<Void, Never>?
    }
}
