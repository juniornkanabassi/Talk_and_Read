// Breeze TTS 2, 8-bit MLX, through the vendored and patched mlx-audio-swift (PLAN 0.4.0 decisions 2-4). The Qwen3
// pattern: each voice clones one bundled reference clip plus its exact transcript (V2); the whole chunk is collected,
// aligned by the shared Parakeet v3 aligner and stop-guarded; prepare, synthesise and unload run on the MLX queue shared
// with Qwen3 (Sol rev. 1). Personal, non-commercial use only (Breeze licence, Sol rev. 6): the app never bundles the
// weights; the user downloads them with consent and `LICENSE`/`NOTICE` stay beside them.
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import TalkReadCore

final class BreezeEngine: SpeechEngine, @unchecked Sendable {   // mutable state is only touched inside `queue`
    var kind: EngineKind { .breeze }

    /// Female, English only (V5; Breeze speaks English and Chinese). Clips are `Resources/Voices/<id>.wav`, Breeze's own
    /// designed voices saying exactly Qwen3's English transcript (decision 3).
    static let references = [
        QwenEngine.Reference(id: "breeze.us_warm", name: "American warm", accent: "American", language: "en", transcript: QwenEngine.english),
        QwenEngine.Reference(id: "breeze.us_calm", name: "American calm", accent: "American", language: "en", transcript: QwenEngine.english),
    ]

    static let repo = "mlx-community/Breeze-TTS-2-mlx-8bit"
    static let revision = "c6e4a2ff6ab9afba68b7853de802273ffe23fb49"
    /// Every file the loader reads, with its size at `revision` (the download's size check), plus the licence. The
    /// loader reads config.json, every *.safetensors in the folder and in audio_tokenizer/, audio_tokenizer/config.json,
    /// tokenizer.json and tokenizer_config.json (swift-transformers 1.3.5 also looks for chat_template.*, absent here),
    /// and writes nothing; the other files are the repository's own, kept so the folder matches it.
    static let files: [(path: String, bytes: Int64)] = [
        ("config.json", 12379), ("generation_config.json", 251), ("model.safetensors", 3_885_721_536),
        ("model.safetensors.index.json", 98863), ("tokenizer.json", 33_386_945), ("tokenizer_config.json", 1_157_960),
        ("special_tokens_map.json", 886), ("audio_tokenizer/config.json", 2336), ("audio_tokenizer/configuration.json", 76),
        ("audio_tokenizer/model.safetensors", 682_293_092), ("audio_tokenizer/preprocessor_config.json", 234),
        ("LICENSE", 18856), ("NOTICE", 146),
    ]
    static var folder: URL { Paths.dataRoot.appendingPathComponent("Models/breeze-tts-2-8bit", isDirectory: true) }
    /// MLX's buffer cache cap while loaded (the port spike's setting: 6.1 GB peak, against 46-56 GB uncapped).
    static let cacheLimit = 512_000_000
    /// Seconds of codec frames decoded per streaming step; the whole chunk is collected either way.
    static let streamingInterval = 2.0
    /// The model's own defaults, frozen (Sol plan review 0.4.0 #3): at most 750 frames (60 s), temperature 0.9, top-k 50,
    /// top-p 1, no repetition penalty. With `voice: nil` there is no instruction, so no classifier-free guidance pass.
    static let parameters = GenerateParameters(maxTokens: 750, temperature: 0.9, topP: 1, topK: 50, repetitionPenalty: 1)
    /// The fastest playback rate a read keeps up at with no hand-over to Kokoro (PLAN 0.4.0 Sol rev. 8: the speed measured
    /// through the real session, not the spike's): 1.5x for both voices, 60 s reads on the M3 Max on mains power, 23 Oct;
    /// at 2x both hand over to Kokoro within 5-40 s. Above it a read starts on Kokoro (ReadSession.start) and choosing
    /// Breeze loads nothing (AppModel.warm); the Voices page and the sustained self-test use it too.
    static let keepsUpTo: Float = 1.5

    let aligner: Aligner
    let queue: MLXQueue
    private var model: BreezeTTSModel?
    private var clips: [String: [Float]] = [:]
    /// The warm-up phrase has run since the load (a cancelled warm-up runs again at the next call, not never).
    private var warmed = false

    init(aligner: Aligner, queue: MLXQueue) { self.aligner = aligner; self.queue = queue }

    var isBusy: Bool { queue.isBusy }
    var keepsUpTo: Float? { Self.keepsUpTo }

    static func modelInstalled() -> Bool {
        files.allSatisfy { f in
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(f.path).path)[.size] as? NSNumber)?.int64Value == f.bytes
        }
    }

    func voices() async -> [Voice] {
        let installed = Self.modelInstalled() && aligner.installed
        return Self.references.map {
            Voice(id: $0.id, name: $0.name, accent: $0.accent, gender: "Female", engine: .breeze, installed: installed, language: $0.language)
        }
    }

    /// Loads the model, the voice's clip and the aligner, and renders one short phrase so the first chunk of a read does
    /// not pay for kernel compilation.
    func prepare(voice: String) async throws {
        try await queue.run { _ = try await self.loaded(voice) }
    }

    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        try await queue.run {
            let (model, clip, ref) = try await self.loaded(voice)
            let started = Date()
            let (samples, info) = try await Self.render(model, text, clip, ref.transcript)
            let rate = Double(model.sampleRate), rendered = Date()
            let aligned = try await self.aligner.align(samples, sampleRate: rate, text: text, language: ref.language)
            Log.write(String(format: "breeze: %d chars, %.2f s audio, render %.2f s (prefill %.3f s), align %.3f s", text.utf16.count,
                             Double(samples.count) / rate, rendered.timeIntervalSince(started), info?.prefillTime ?? -1,
                             Date().timeIntervalSince(rendered)))
            return SynthChunk(samples: aligned.samples, sampleRate: rate, words: aligned.words)
        }
    }

    /// Releases the weights, the clips, the aligner and MLX's cache, after any work in flight; queued before this
    /// returns, so `isBusy` is true at once (Sol plan review 0.4.0 #5).
    func unload() {
        queue.enqueue {
            self.model = nil
            self.clips = [:]
            self.warmed = false
            await self.aligner.unload()
            Memory.clearCache()
        }
    }

    // MARK: - Inside the queue

    private func loaded(_ voice: String) async throws -> (BreezeTTSModel, [Float], QwenEngine.Reference) {
        guard let ref = Self.references.first(where: { $0.id == voice }) else { throw SpeechError.render("unknown Breeze voice \(voice)") }
        let started = Date()
        if model == nil {
            guard Self.modelInstalled() else { throw SpeechError.render("the Breeze TTS 2 model is not downloaded") }
            Memory.cacheLimit = Self.cacheLimit
            guard let m = try await TTS.loadModel(modelRepo: Self.folder.path) as? BreezeTTSModel else { throw SpeechError.render("not a Breeze TTS model") }
            model = m
        }
        let model = model!
        if clips[voice] == nil {
            guard let url = QwenEngine.clip(voice) else { throw SpeechError.render("missing reference clip for \(voice)") }
            clips[voice] = try loadAudioArray(from: url, sampleRate: model.sampleRate).1.asArray(Float.self)
        }
        let clip = clips[voice]!
        if !warmed {
            let loadedAt = Date()
            let phrase = "Ready."
            let warm = try await Self.render(model, phrase, clip, ref.transcript).samples
            let warmedAt = Date()
            _ = try await aligner.align(warm, sampleRate: Double(model.sampleRate), text: phrase, language: ref.language)
            warmed = true
            Log.write(String(format: "breeze: model and %@ in %.1f s, warm-up %.1f s, aligner %.1f s", voice, loadedAt.timeIntervalSince(started),
                             warmedAt.timeIntervalSince(loadedAt), Date().timeIntervalSince(warmedAt)))
        }
        return (model, clip, ref)
    }

    /// One chunk through the queue's join-on-cancel collection: the catalogue id only picked the clip; the dependency
    /// gets no instruction (`voice: nil`), the clip's waveform and its exact transcript (Sol plan review 0.4.0 #3).
    private static func render(_ model: BreezeTTSModel, _ text: String, _ clip: [Float], _ transcript: String) async throws -> (samples: [Float], info: AudioGenerationInfo?) {
        try await MLXQueue.collect {
            model.generateStream(text: text, voice: nil, refAudio: MLXArray(clip), refText: transcript, language: nil,
                                 generationParameters: parameters, streamingInterval: streamingInterval)
        }
    }
}

extension BreezeEngine: DownloadableModel {
    /// The UI matches Models page rows on "Breeze" in the title.
    var title: String { "Breeze TTS 2 expressive voices" }
    var modelMegabytes: Int { Int(Self.files.reduce(0) { $0 + $1.bytes } / 1_000_000) }
    var isModelInstalled: Bool { Self.modelInstalled() }
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/")!
        try await ModelDownload.fetch(Self.files, from: base, into: Self.folder, progress: progress)
    }
}
