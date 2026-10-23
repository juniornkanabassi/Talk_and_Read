// Word timing for the natural voices (PLAN 0.3.0 decision 4): Parakeet TDT v3 (FluidAudio, English and French) listens
// to each synthesised chunk and returns its words in chunk-local seconds (`range: nil`); ReadSession maps them onto the
// text through `Timeline` with the voice's language. Also the stop guard (decision 9).
import FluidAudio
import Foundation
import TalkReadCore

/// Not thread-safe by itself: QwenEngine calls it only from inside its one serial queue.
final class Aligner: @unchecked Sendable {
    /// FluidAudio's own cache folder by default (exempt from "<data root>/Models only", PLAN 0.3.0 decision 6); the
    /// self-test passes a local copy so nothing is downloaded.
    let directory: URL
    private var manager: AsrManager?

    init(directory: URL? = nil) { self.directory = directory ?? AsrModels.defaultCacheDirectory(for: .v3) }

    var installed: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    /// Loads Parakeet v3 when it is on disk. Never downloads: that needs the user's consent on the Models page.
    func load() async throws -> AsrManager? {
        if let manager { return manager }
        guard installed else { return nil }
        let m = AsrManager(config: .default)
        try await m.loadModels(try await AsrModels.load(from: directory, version: .v3))
        manager = m
        return m
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// The chunk's audio after the stop guard and its words, chunk-local. No words when the model is not installed
    /// (Timeline then spreads the chunk's tokens over its audio by length).
    func align(_ samples: [Float], sampleRate: Double, text: String, language: String) async throws -> (samples: [Float], words: [SpokenWord]) {
        guard let asr = try await load() else { return (samples, []) }
        let audio = try AudioConverter().resample(samples, from: sampleRate)
        var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audio, decoderState: &state, language: language == "fr" ? .french : .english)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map { SpokenWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
        let matched = Alignment.assign(spoken: words.map(\.text), source: TextKit.tokenize(text).map(\.text), language: language)
        let lastEnd = matched.lastIndex { $0 != nil }.map { words[$0].end } ?? 0
        let keep = Self.keptSamples(samples, sampleRate: sampleRate, lastMatchedEnd: lastEnd)
        return (keep < samples.count ? Array(samples[..<keep]) : samples, words)
    }

    /// Stop guard (PLAN 0.3.0 decision 9): how many samples to keep. Speech ends at the later of the last matched word's
    /// end and the last audible 10 ms frame (RMS within 40 dB of the chunk's loudest frame); a silent tail longer than
    /// 300 ms after that is cut to 150 ms. Audible audio is never cut, so an ASR miss alone trims nothing that is heard.
    static func keptSamples(_ samples: [Float], sampleRate: Double, lastMatchedEnd: Double) -> Int {
        let hop = max(Int(sampleRate / 100), 1)
        let rms: [Float] = stride(from: 0, to: samples.count, by: hop).map { i in
            let frame = samples[i ..< min(i + hop, samples.count)]
            return (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        }
        let floor = max((rms.max() ?? 0) * 0.01, 1e-4)
        let lastAudible = rms.lastIndex { $0 >= floor }.map { Double(($0 + 1) * hop) / sampleRate } ?? 0
        let speechEnd = max(lastMatchedEnd, lastAudible)
        guard Double(samples.count) / sampleRate - speechEnd > 0.3 else { return samples.count }
        return min(samples.count, Int(((speechEnd + 0.15) * sampleRate).rounded()))
    }
}

extension Aligner: DownloadableModel {
    /// V-C matches Models page rows on "Parakeet" in the title.
    var title: String { "Word timing for natural voices (Parakeet v3)" }
    /// Parakeet TDT v3 int8 as FluidAudio fetches it (measured on the 23 Oct spike copy).
    var modelMegabytes: Int { 483 }
    var isModelInstalled: Bool { installed }
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(to: directory, version: .v3) { progress($0.fractionCompleted) }
    }
}
