// Voice catalogue types, the SpeechEngine protocol, the Engines pair and the speech errors.
// Each engine lists its own voices (`voices()`); the neural list reports whether the Kokoro model is downloaded.
import Foundation
import TalkReadCore

enum EngineKind: String, Codable { case neural, system }

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: String
    let gender: String
    let engine: EngineKind
    var installed: Bool
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

final class Engines {
    let neural: SpeechEngine
    let system: SpeechEngine
    init(neural: SpeechEngine = NeuralEngine(), system: SpeechEngine = SystemEngine()) { self.neural = neural; self.system = system }
    func engine(for v: Voice) -> SpeechEngine { v.engine == .neural ? neural : system }
}
