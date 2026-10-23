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
}

/// A large model the user downloads with consent (Qwen3, the Parakeet v3 aligner, the Kokoro French pack): the Models
/// page lists these with their sizes; nothing downloads before the user says so (PLAN 0.3.0, Sol plan review 1 #1, #6).
@MainActor protocol DownloadableModel: AnyObject {
    var title: String { get }
    var modelMegabytes: Int { get }
    var isModelInstalled: Bool { get }
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws
}

final class Engines {
    let neural: SpeechEngine
    let system: SpeechEngine
    init(neural: SpeechEngine = NeuralEngine(), system: SpeechEngine = SystemEngine()) { self.neural = neural; self.system = system }
    // Contract for 0.3.0 (V-A fills in the MLX engines; V-C calls these and never the engines' properties directly).
    func engine(for v: Voice) -> SpeechEngine { v.engine == .neural ? neural : system }
    /// Every engine's voices, all languages and genders; the UI filters (female only, by model, by language).
    func allVoices() async -> [Voice] { await neural.voices() + system.voices() }
    /// Models the user may download, with sizes (Models page and onboarding).
    @MainActor func downloadables() -> [DownloadableModel] { [] }
    /// Preparing, synthesising or unloading somewhere: the idle unload waits.
    var isBusy: Bool { false }
    /// Frees every engine's model memory (idle timer, quit). An engine finishes its in-flight work first.
    func unloadAll() { neural.unload(); system.unload() }
}
