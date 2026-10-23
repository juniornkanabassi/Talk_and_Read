// Qwen3-TTS 1.7B Base, 8-bit MLX, through mlx-audio-swift (PLAN 0.3.0 decision 3). Each voice clones one bundled
// reference clip plus its exact transcript, so a read keeps one voice from its first chunk to its last (V2). Chunks come
// back whole (no streaming contract), with words from the Parakeet v3 aligner and the stop guard applied.
// One serial queue runs prepare, synthesise and unload in order (decision 5): MLX state is never touched concurrently, an
// unload waits for the chunk in flight, and `isBusy` counts queued and running work.
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import os
import TalkReadCore

final class QwenEngine: SpeechEngine, @unchecked Sendable {   // mutable state is only touched inside `serial`
    var kind: EngineKind { .qwen }

    struct Reference { let id, name, accent, language, transcript: String }
    static let english = "Hello, and welcome back. I'll be reading this for you today at a calm, steady pace. If you'd like me to slow down or speed up, just let me know, and we'll carry on together."
    static let french = "Bonjour et bienvenue. Je vais vous lire ce texte aujourd'hui, à un rythme calme et régulier. Si vous voulez que je ralentisse ou que j'accélère, dites-le-moi, et nous continuerons ensemble."
    /// Female only (V5). Clips are `Resources/Voices/<id>.wav`, made 23 Oct from VoiceDesign descriptions (Design/Voice samples).
    static let references = [
        Reference(id: "qwen.us_warm", name: "American warm", accent: "American", language: "en", transcript: english),
        Reference(id: "qwen.us_calm", name: "American calm", accent: "American", language: "en", transcript: english),
        Reference(id: "qwen.fr_warm", name: "French warm", accent: "French", language: "fr", transcript: french),
    ]

    static let repo = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
    static let revision = "e7dd0585652209fa0d7783659aad4e8a324de11c"
    /// Every file the loader reads, with its size at `revision` (the download's size check). The loader writes
    /// tokenizer.json beside them on first load, which is why the folder is the app's own.
    static let files: [(path: String, bytes: Int64)] = [
        ("config.json", 5522), ("generation_config.json", 245), ("merges.txt", 1_671_839),
        ("model.safetensors", 2_417_320_525), ("model.safetensors.index.json", 78070), ("preprocessor_config.json", 127),
        ("tokenizer_config.json", 7344), ("vocab.json", 2_776_833),
        ("speech_tokenizer/config.json", 2336), ("speech_tokenizer/configuration.json", 76),
        ("speech_tokenizer/model.safetensors", 682_293_092), ("speech_tokenizer/preprocessor_config.json", 234),
    ]
    static var folder: URL { Paths.dataRoot.appendingPathComponent("Models/qwen3-tts-base-8bit", isDirectory: true) }
    /// MLX's buffer cache cap while loaded (the spike's setting; the default cache grows to several GB).
    static let cacheLimit = 512_000_000
    /// Seconds of codec frames decoded per streaming step; the whole chunk is collected either way. Measured 23 Oct on the
    /// French fixture: 0.32 s gave 3.17x real time, 2.0 s 3.35-3.39x, 5 s and more no better.
    static let streamingInterval = 2.0

    let aligner: Aligner
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var queued = 0
    private var model: Qwen3TTSModel?
    private var conditionings: [String: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]

    init(aligner: Aligner) { self.aligner = aligner }

    var isBusy: Bool { lock.withLock { queued > 0 } }

    static func modelInstalled() -> Bool {
        files.allSatisfy { f in
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(f.path).path)[.size] as? NSNumber)?.int64Value == f.bytes
        }
    }

    func voices() async -> [Voice] {
        let installed = Self.modelInstalled() && aligner.installed
        return Self.references.map {
            Voice(id: $0.id, name: $0.name, accent: $0.accent, gender: "Female", engine: .qwen, installed: installed, language: $0.language)
        }
    }

    /// Loads the model, the voice's conditioning and the aligner, and renders one short phrase so the first chunk of a
    /// read does not pay for kernel compilation.
    func prepare(voice: String) async throws {
        try await serial { _ = try await self.loaded(voice) }
    }

    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        try await serial {
            let (model, conditioning, language) = try await self.loaded(voice)
            let started = Date()
            let samples = try await Self.render(model, text, conditioning)
            let rate = Double(model.sampleRate), rendered = Date()
            let aligned = try await self.aligner.align(samples, sampleRate: rate, text: text, language: language)
            Log.write(String(format: "qwen: %d chars, %.2f s audio, render %.2f s, align %.3f s", text.utf16.count, Double(samples.count) / rate,
                             rendered.timeIntervalSince(started), Date().timeIntervalSince(rendered)))
            return SynthChunk(samples: aligned.samples, sampleRate: rate, words: aligned.words)
        }
    }

    /// Releases the weights, every voice's conditioning, the aligner and MLX's cache, after any work in flight.
    func unload() {
        Task { try? await serial {
            self.model = nil
            self.conditionings = [:]
            await self.aligner.unload()
            Memory.clearCache()
        } }
    }

    // MARK: - Inside the queue

    private func loaded(_ voice: String) async throws -> (Qwen3TTSModel, Qwen3TTSModel.Qwen3TTSReferenceConditioning, String) {
        guard let ref = Self.references.first(where: { $0.id == voice }) else { throw SpeechError.render("unknown Qwen3 voice \(voice)") }
        var fresh = false
        let started = Date()
        if model == nil {
            guard Self.modelInstalled() else { throw SpeechError.render("the Qwen3-TTS model is not downloaded") }
            Memory.cacheLimit = Self.cacheLimit
            guard let m = try await TTS.loadModel(modelRepo: Self.folder.path) as? Qwen3TTSModel else { throw SpeechError.render("not a Qwen3-TTS model") }
            model = m
            fresh = true
        }
        let model = model!
        if conditionings[voice] == nil {
            guard let clip = Self.clip(voice) else { throw SpeechError.render("missing reference clip for \(voice)") }
            let (_, audio) = try loadAudioArray(from: clip, sampleRate: model.sampleRate)
            let raw = try model.prepareReferenceConditioning(refAudio: audio, refText: ref.transcript, language: ref.language == "fr" ? "french" : "english")
            // The Base speaker embedding comes out float32 and would promote every decoding step to float32
            // (1.4x instead of 3.4x real time, spike 23 Oct).
            let c = Qwen3TTSModel.Qwen3TTSReferenceConditioning(
                speakerEmbedding: raw.speakerEmbedding?.asType(.bfloat16), referenceSpeechCodes: raw.referenceSpeechCodes,
                referenceTextTokenIDs: raw.referenceTextTokenIDs, resolvedLanguage: raw.resolvedLanguage, codecLanguageID: raw.codecLanguageID)
            eval(c.referenceSpeechCodes)
            conditionings[voice] = c
        }
        let conditioning = conditionings[voice]!
        if fresh {
            let loadedAt = Date()
            let phrase = ref.language == "fr" ? "Prêt." : "Ready."
            let warm = try await Self.render(model, phrase, conditioning)
            let warmedAt = Date()
            _ = try await aligner.align(warm, sampleRate: Double(model.sampleRate), text: phrase, language: ref.language)
            Log.write(String(format: "qwen: model and %@ in %.1f s, warm-up %.1f s, aligner %.1f s", voice, loadedAt.timeIntervalSince(started),
                             warmedAt.timeIntervalSince(loadedAt), Date().timeIntervalSince(warmedAt)))
        }
        return (model, conditioning, ref.language)
    }

    /// Streams the chunk and returns only once the dependency's generation has ended (Sol inspection 4 #1). `generateStream`
    /// generates in a task of its own, which ending the stream (our cancellation) cancels but nothing joins; that task
    /// inherits `probe` and releases it when it ends, so waiting for the probe's release joins it, whatever our
    /// cancellation (were the dependency to start it detached, `--cancel` would fail). Streaming in 2 s decode steps, not
    /// the awaitable non-streaming `generate`: that decodes the reference clip with every chunk, about 2 GB more at peak
    /// (7.4 against 5.3-5.5 GB at 2.5x, 23 Oct).
    private static func render(_ model: Qwen3TTSModel, _ text: String, _ conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning) async throws -> [Float] {
        let (released, release) = AsyncStream<Void>.makeStream()
        let joined = Task { for await _ in released {} }   // created outside the binding, and not cancelled with us
        let samples: [Float]
        do {
            samples = try await $probe.withValue(Probe(release)) {
                var samples: [Float] = []
                for try await event in model.generateStream(text: text, conditioning: conditioning, generationParameters: model.defaultGenerationParameters,
                                                            streamingInterval: streamingInterval) {
                    if case .audio(let a) = event { samples += a.asArray(Float.self) }
                }
                return samples
            }
        } catch {
            await joined.value
            throw error
        }
        await joined.value
        try Task.checkCancellation()   // a cancelled stream just ends: its partial chunk is no result
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw SpeechError.badAudio }
        return samples
    }

    /// Qwen3 generations still running and the most at once since the last reset (the cancel/restart self-test): every
    /// task the dependency starts inside `render` inherits `probe` and holds it until that task ends.
    static let generations = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
    @TaskLocal private static var probe: Probe?
    private final class Probe: Sendable {
        let release: AsyncStream<Void>.Continuation
        init(_ release: AsyncStream<Void>.Continuation) {
            self.release = release
            QwenEngine.generations.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        }
        deinit {
            QwenEngine.generations.withLock { $0.now -= 1 }
            release.finish()
        }
    }

    /// The bundled clip; in a `swift build` run (no app bundle) the source tree's copy.
    static func clip(_ id: String) -> URL? {
        if let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "Voices") { return url }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/Voices/\(id).wav").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Runs `op` after every earlier call has finished. Cancelling the caller cancels `op` (generation checks for it
    /// every frame), so an abandoned chunk frees the GPU within a frame or two.
    private func serial<T>(_ op: @escaping () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            let previous = tail
            queued += 1
            let t = Task.detached(priority: .userInitiated) { [self] () async throws -> T in
                defer { lock.withLock { queued -= 1 } }
                await previous?.value
                try Task.checkCancellation()
                return try await op()
            }
            tail = Task.detached { _ = try? await t.value }
            return t
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

extension QwenEngine: DownloadableModel {
    /// V-C matches Models page rows on "Qwen3" in the title.
    var title: String { "Qwen3 natural voices (1.7B)" }
    var modelMegabytes: Int { Int(Self.files.reduce(0) { $0 + $1.bytes } / 1_000_000) }
    var isModelInstalled: Bool { Self.modelInstalled() }
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/")!
        try await ModelDownload.fetch(Self.files, from: base, into: Self.folder, progress: progress)
    }
}

/// The app's own model downloader (PLAN 0.3.0 decision 6): every file into a staging folder beside the target, each
/// checked against its expected size, then the folder moved into place; redirects are followed only to Hugging Face. A
/// failed or cancelled download leaves no staging folder behind (gigabytes, Sol inspection 4 #5).
enum ModelDownload {
    enum Failure: Error, LocalizedError {
        case size(String, expected: Int64, got: Int64), status(String, Int)
        var errorDescription: String? {
            switch self {
            case .size(let f, let e, let g): return "\(f): expected \(e) bytes, got \(g)"
            case .status(let f, let s): return "\(f): HTTP \(s)"
            }
        }
    }

    /// `huggingface.co`, `*.huggingface.co`, `*.hf.co`, over https only.
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    static func fetch(_ files: [(path: String, bytes: Int64)], from base: URL, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".\(folder.lastPathComponent).partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }   // any failure or cancellation; after the move there is nothing left
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Double(files.reduce(0) { $0 + $1.bytes })
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            try await FileDownload(target: target) { progress(Double(before + $0) / total) }.run(base.appendingPathComponent(file.path))
            let size = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == file.bytes else { throw Failure.size(file.path, expected: file.bytes, got: size) }
            done += file.bytes
        }
        try? fm.removeItem(at: folder)   // a half-installed or older copy
        try fm.moveItem(at: staging, to: folder)
        progress(1)
    }
}

/// One URLSession download with progress, the redirect rule and the move out of URLSession's temporary file.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {   // callbacks are serial
    let target: URL
    let progress: (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(target: URL, progress: @escaping (Int64) -> Void) { self.target = target; self.progress = progress }

    func run(_ url: URL) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(ModelDownload.allowed(request.url) ? request : nil)   // refused: the 3xx fails the status check
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = ModelDownload.Failure.status(target.lastPathComponent, http.statusCode)
            return
        }
        do {   // the temporary file is deleted when this returns
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? failure { continuation?.resume(throwing: e) } else { continuation?.resume() }
        continuation = nil
    }
}
