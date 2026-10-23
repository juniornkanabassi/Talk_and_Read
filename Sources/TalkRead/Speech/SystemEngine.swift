// AVSpeechSynthesizer fallback engine (no download). Renders offline with `write(_:toBufferCallback:toMarkerCallback:)`;
// word markers give exact UTF-16 ranges in the spoken text and their sample offsets.
import AVFoundation
import Foundation
import TalkReadCore

final class SystemEngine: SpeechEngine {
    var kind: EngineKind { .system }

    func voices() async -> [Voice] { Self.ranked("en").map { Self.voice($0, language: "en") } }

    /// The best installed voice of `language` ("en", "fr"): a fallback keeps the read's language, where `voices()` lists
    /// English only (Sol inspection 4 #3).
    static func voice(language: String) -> Voice? { ranked(language).first.map { voice($0, language: language) } }

    /// Best first: Premium > Enhanced > default, then en-GB, en-US, other variants; Apple voices before Eloquence.
    static func ranked(_ language: String) -> [AVSpeechSynthesisVoice] {
        func key(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int, String) {
            (-v.quality.rawValue, v.language == "en-GB" ? 0 : v.language == "en-US" ? 1 : 2,
             v.identifier.contains("eloquence") ? 1 : 0, v.name)
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { key($0) < key($1) }
    }

    private static func voice(_ v: AVSpeechSynthesisVoice, language: String) -> Voice {
        let accent = v.language == "en-GB" ? "British" : v.language == "en-US" ? "American" : v.language
        let gender = v.gender == .female ? "Female" : v.gender == .male ? "Male" : ""
        return Voice(id: v.identifier, name: v.name, accent: accent, gender: gender, engine: .system, installed: true, language: language)
    }

    func prepare(voice: String) async throws {}

    /// An unknown `voice` id ("" when no voice of the language is installed) uses the best installed English voice.
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice) ?? Self.ranked("en").first
        let job = Job(text: text)
        defer { withExtendedLifetime(job) {} }   // the synthesizer's callbacks hold the job weakly
        return try await withCheckedThrowingContinuation { job.run(utterance, $0) }
    }

    func unload() {}
}

/// One utterance. Kept alive by `synthesize` while it awaits; callbacks hold it weakly.
private final class Job: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {   // callbacks are serialised by the synthesizer
    let text: String
    let synthesizer = AVSpeechSynthesizer()
    var samples: [Float] = []
    var rate = 22_050.0
    var bytesPerSample = 4.0
    /// Word marker start (samples) and UTF-16 range in `text`.
    var marks: [(sample: Double, range: NSRange)] = []
    /// macOS 27 restarts `byteSampleOffset` at 0 every ~12 s of audio (at a sentence); markers arrive just as their
    /// audio does, so a restart is rebased on the samples received so far.
    var segmentBase = 0.0
    var lastOffset = 0.0
    var continuation: CheckedContinuation<SynthChunk, Error>?

    init(text: String) { self.text = text }

    func run(_ utterance: AVSpeechUtterance, _ c: CheckedContinuation<SynthChunk, Error>) {
        continuation = c
        synthesizer.delegate = self
        synthesizer.write(utterance, toBufferCallback: { [weak self] buffer in
            // Empty buffers also arrive mid-utterance on macOS 27, so the end is the delegate's didFinish, not this.
            guard let self, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            let n = Int(pcm.frameLength)
            self.rate = pcm.format.sampleRate
            self.bytesPerSample = Double(pcm.format.streamDescription.pointee.mBytesPerFrame)
            if let f = pcm.floatChannelData {
                self.samples += UnsafeBufferPointer(start: f[0], count: n)
            } else if let i = pcm.int16ChannelData {
                self.samples += UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32_768 }
            }
        }, toMarkerCallback: { [weak self] markers in
            guard let self else { return }
            for m in markers where m.mark == .word {
                let offset = Double(m.byteSampleOffset) / self.bytesPerSample
                if offset < self.lastOffset { self.segmentBase = Double(self.samples.count) - offset }
                self.lastOffset = offset
                self.marks.append((self.segmentBase + offset, m.textRange))
            }
        })
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return finish(.failure(SpeechError.badAudio)) }
        let duration = Double(samples.count) / rate
        let ns = text as NSString
        var words: [SpokenWord] = []
        if marks.isEmpty {
            // ponytail: no markers (never seen on macOS 27) -> spread the tokens over the audio by length.
            let tokens = TextKit.tokenize(text)
            let total = Double(tokens.reduce(0) { $0 + $1.range.count })
            var t = 0.0
            for tok in tokens {
                let d = duration * Double(tok.range.count) / max(total, 1)
                words.append(SpokenWord(text: tok.text, start: t, end: t + d, range: tok.range))
                t += d
            }
        } else {
            let starts = marks.map { min($0.sample / rate, duration) }
            for (i, m) in marks.enumerated() {
                let end = i + 1 < starts.count ? max(starts[i + 1], starts[i]) : duration
                words.append(SpokenWord(text: ns.substring(with: m.range), start: starts[i], end: end,
                                        range: m.range.location ..< m.range.location + m.range.length))
            }
        }
        finish(.success(SynthChunk(samples: samples, sampleRate: rate, words: words)))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        finish(.failure(CancellationError()))
    }

    private func finish(_ r: Result<SynthChunk, Error>) {
        continuation?.resume(with: r)
        continuation = nil
    }
}
