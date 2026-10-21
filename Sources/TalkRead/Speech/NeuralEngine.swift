// FluidAudio Kokoro engine: text chunk -> PCM plus per-word timings. Stub; owned by WP3.
import FluidAudio
import Foundation

final class NeuralEngine: SpeechEngine {
    var kind: EngineKind { .neural }
    func voices() async -> [Voice] { [] }
    func prepare(voice: String) async throws { fatalError("WP3") }
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk { fatalError("WP3") }
    func unload() {}
}
