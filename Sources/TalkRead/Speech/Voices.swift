// Voice catalogue types, the SpeechEngine protocol and the Engines pair. Types are scaffold; catalogue and download state are WP3.
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
