// FluidAudio Parakeet Unified 0.6B streaming recogniser (640 ms tier, int8; PLAN decision 4): warm model, one utterance
// at a time, live partials, and file transcription through the same path.
import AVFoundation
import FluidAudio

/// What the dictation controller needs from a recogniser (the real `Transcriber`, or a fake in the self-test).
@MainActor protocol DictationASR: AnyObject {
    /// Transcribes one utterance: every buffer of `audio` (16 kHz mono Float32) until the stream finishes.
    func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> String
    func load(progress: ((Double) -> Void)?) async throws
    func unload()
    var isLoaded: Bool { get }
}

extension DictationASR {
    /// Whole-clip transcription (dictate-file, self-test): fed in 1 s buffers, then finished.
    func transcribe(samples: [Float]) async throws -> String {
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            feed.yield(Transcriber.buffer(samples[start..<min(start + 16_000, samples.count)]))
        }
        feed.finish()
        return try await run(stream, partial: { _ in })
    }
}

@MainActor final class Transcriber: DictationASR {
    static let variant = StreamingModelVariant.parakeetUnified640ms
    private var manager: StreamingUnifiedAsrManager?
    private var loading: Task<StreamingUnifiedAsrManager, Error>?
    private var inUse = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isLoaded: Bool { manager != nil }

    /// The model files are already in FluidAudio's cache (no download needed).
    static var isDownloaded: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(Repo.parakeetUnified.folderName)")
        let names = ModelNames.ParakeetUnified.self
        let encoder = names.streamingEncoderFile(precision: .int8, contextSuffix: variant.unifiedConfig!.contextSuffix)
        return [encoder, names.decoderFile, names.jointDecisionFile, names.vocab]
            .allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Downloads (huggingface.co, first use only) and loads the model; later calls return at once.
    func load(progress: ((Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if loading == nil {
            loading = Task {
                let m = StreamingUnifiedAsrManager(config: Self.variant.unifiedConfig!, encoderPrecision: .int8)
                try await m.loadModels(to: nil, configuration: nil) { p in
                    Task { @MainActor in progress?(p.fractionCompleted) }
                }
                return m
            }
        }
        defer { loading = nil }
        manager = try await loading!.value
    }

    func unload() {
        guard !inUse, let m = manager else { return }
        manager = nil
        Task { await m.cleanup() }
    }

    func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        // One utterance at a time: the manager is reset per utterance and its state is not shareable.
        if inUse { await withCheckedContinuation { waiting.append($0) } }
        inUse = true
        defer {
            if waiting.isEmpty { inUse = false } else { waiting.removeFirst().resume() }   // hand over, still in use
        }
        try await load()
        guard let m = manager else { throw ASRError.notInitialized }
        try await m.reset()
        await m.setPartialTranscriptCallback { text in Task { @MainActor in partial(text) } }
        var frames = 0
        for await buffer in audio {
            try Task.checkCancellation()
            try await m.appendAudio(buffer)
            frames += Int(buffer.frameLength)
            try await m.processBufferedAudio()
        }
        try Task.checkCancellation()
        if frames < 16_000 { try await m.appendAudio(Self.buffer(ArraySlice(repeating: 0, count: 16_000 - frames))) }
        let text = try await m.finish()
        await m.setPartialTranscriptCallback { _ in }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
