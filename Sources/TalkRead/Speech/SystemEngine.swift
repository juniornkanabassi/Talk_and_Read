// AVSpeechSynthesizer fallback engine (no download), word timings from speech markers. Stub; owned by WP3.
import AVFoundation
import Foundation

final class SystemEngine: SpeechEngine {
    var kind: EngineKind { .system }
    func voices() async -> [Voice] { [] }
    func prepare(voice: String) async throws { fatalError("WP3") }
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk { fatalError("WP3") }
    func unload() {}
}
