// Voice catalogue types, the SpeechEngine protocol, the Engines pair and the speech errors.
// Each engine lists its own voices (`voices()`); the neural list reports whether the Kokoro model is downloaded.
import Foundation
import TalkReadCore

/// `neural` is Kokoro; `qwen` and `breeze` are the MLX models added in 0.3.0 (PLAN 0.3.0 decision 1).
enum EngineKind: String, Codable { case neural, system, qwen, breeze }

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: String
    let gender: String
    let engine: EngineKind
    var installed: Bool
    /// `en` or `fr` (PLAN 0.3.0 decision 2).
    var language = "en"
}

/// One synthesised chunk; `words` are chunk-local seconds.
struct SynthChunk {
    let samples: [Float]
    let sampleRate: Double
    let words: [SpokenWord]
}

enum SpeechError: Error, LocalizedError {
    /// No samples, or non-finite ones (the Kokoro v3 NaN regression on macOS 27).
    case badAudio
    case render(String)
    var errorDescription: String? {
        switch self {
        case .badAudio: return "The voice produced no usable audio."
        case .render(let why): return "Audio render failed: \(why)"
        }
    }
}

protocol SpeechEngine: AnyObject {
    var kind: EngineKind { get }
    func voices() async -> [Voice]
    func prepare(voice: String) async throws
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk
    func unload()
    /// Preparing, synthesising or unloading right now (V-A, additive): the idle unload waits for it.
    var isBusy: Bool { get }
}

extension SpeechEngine {
    var isBusy: Bool { false }
    /// Renders well below real time, so a read uses bounded chunks, the time budget and the Kokoro fallback (V3).
    var isSlow: Bool { kind == .qwen || kind == .breeze }
}

/// A large model the user downloads with consent (Qwen3, the Parakeet v3 aligner, the Kokoro French pack): the Models
/// page lists these with their sizes; nothing downloads before the user says so (PLAN 0.3.0, Sol plan review 1 #1, #6).
@MainActor protocol DownloadableModel: AnyObject {
    var title: String { get }
    var modelMegabytes: Int { get }
    var isModelInstalled: Bool { get }
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Every engine, injectable for tests (the self-test passes slow and fast fakes).
final class Engines {
    let neural: SpeechEngine
    let system: SpeechEngine
    let qwen: SpeechEngine
    let aligner: Aligner
    init(neural: SpeechEngine = NeuralEngine(), system: SpeechEngine = SystemEngine(), qwen: SpeechEngine? = nil, aligner: Aligner = Aligner()) {
        self.neural = neural
        self.system = system
        self.aligner = aligner
        self.qwen = qwen ?? QwenEngine(aligner: aligner)
    }
    // Contract for 0.3.0 (V-C calls these and never the engines' properties directly).
    func engine(for v: Voice) -> SpeechEngine {
        switch v.engine {
        case .neural: neural
        case .qwen: qwen
        case .system, .breeze: system   // Breeze is not offered until its port keeps up (PLAN 0.3.0 decision 7)
        }
    }
    /// Every engine's voices, all languages and genders; the UI filters (female only, by model, by language).
    func allVoices() async -> [Voice] { await neural.voices() + qwen.voices() + system.voices() }
    /// Models the user may download, with sizes (Models page and onboarding).
    @MainActor func downloadables() -> [DownloadableModel] {
        [qwen as? DownloadableModel, aligner, (neural as? NeuralEngine)?.frenchPack].compactMap { $0 }
    }
    /// Preparing, synthesising or unloading somewhere: the idle unload waits.
    var isBusy: Bool { neural.isBusy || qwen.isBusy || system.isBusy }
    /// Frees every engine's model memory (idle timer, quit). An engine finishes its in-flight work first.
    func unloadAll() { unloads += 1; neural.unload(); system.unload(); qwen.unload() }
    /// How many times `unloadAll` ran: a read's warm fallback is cold again once this moves (Sol inspection 4 #2).
    private(set) var unloads = 0
}
