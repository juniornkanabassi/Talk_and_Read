// FluidAudio Kokoro-82M (ANE v3) engine: text chunk -> 24 kHz PCM plus per-word timings taken from the model's own
// predicted durations (PLAN decision 1). Words come from walking `inputIds`/`predictedDurations` and pairing the
// space-separated groups with the words of Kokoro's normalised text.
import FluidAudio
import Foundation
import TalkReadCore

final class NeuralEngine: SpeechEngine {
    var kind: EngineKind { .neural }
    private let loader = KokoroLoader()

    /// Kokoro vocab ids (vocab.json of the pinned ANE-v3 English checkpoint): BOS/EOS = 0, space = 16.
    static let boundaryIds: Set<Int32> = [0, 16]
    /// `; : , . ! ? — … " ( ) “ ”`: prosody tokens. They never open a word and do not stretch its span.
    static let punctuationIds: Set<Int32> = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15]
    /// One acoustic frame of `predictedDurations` is 600 samples (25 ms at 24 kHz).
    static let samplesPerFrame = 600.0
    // ponytail: constant shift, measured 21 Oct on the fixture with `--selftest-tts`: duration-derived starts sat a median
    // 40 ms after the audio's energy onset and 70 ms after Parakeet v2's word starts (hexgrad notes a lead of a few
    // frames); -50 ms (two frames) suits both. Re-measure if the model or FluidAudio's chain changes.
    static let startOffset = -0.05

    func voices() async -> [Voice] {
        let installed = Self.modelInstalled()
        // English packs only for 1.0; other prefixes (e/f/h/i/j/p/z) are other languages.
        let kinds = ["bf": ("British", "Female"), "bm": ("British", "Male"), "af": ("American", "Female"), "am": ("American", "Male")]
        return KokoroAneConstants.englishVoices.compactMap { id -> Voice? in
            guard let (accent, gender) = kinds[String(id.prefix(2))] else { return nil }
            return Voice(id: id, name: String(id.dropFirst(3)).capitalized, accent: accent, gender: gender, engine: .neural, installed: installed)
        }
        .sorted { ($0.accent == "British" ? 0 : 1, $0.name) < ($1.accent == "British" ? 0 : 1, $1.name) }
    }

    /// The v3 English checkpoint writes `vocab.json` last, after every model file has been fetched.
    static func modelInstalled() -> Bool {
        guard let root = try? TtsCacheDirectory.ensure().appendingPathComponent("Models/kokoro-82m-coreml/ANE-v3") else { return false }
        let revisions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return revisions.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/en/vocab.json").path) }
    }

    func prepare(voice: String) async throws {
        try await loader.manager().initialize(preloadVoices: [voice])
    }

    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let manager = try await loader.manager()
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: 1)
        guard !result.samples.isEmpty, result.samples.allSatisfy(\.isFinite) else { throw SpeechError.badAudio }
        let rate = Double(result.sampleRate)
        let groups = Self.groups(ids: result.inputIds, durations: result.predictedDurations, frame: Self.samplesPerFrame / rate)
        let words = Self.words(in: result.normalizedText ?? text)
        var counts: [Int]?
        if groups.count != words.count {
            // The phonemiser is per word, so phonemising each word alone tells how many groups it produced
            // (an unlisted hyphenated compound gives one group per part, an unpronounceable token gives none).
            var c: [Int] = []
            for w in words {
                let ipa = (try? await manager.phonemes(for: w)) ?? ""
                c.append(ipa.split(separator: " ").filter { $0.contains(where: \.isLetter) }.count)
            }
            counts = c
        }
        let duration = Double(result.samples.count) / rate
        return SynthChunk(samples: result.samples, sampleRate: rate,
                          words: Self.pair(words, groups, counts: counts, offset: Self.startOffset, duration: duration))
    }

    func unload() {
        Task { await loader.drop() }
    }

    // MARK: - Pure helpers (checked by `--selftest-tts`)

    /// Word spans in seconds: runs of ids between boundaries (space, BOS/EOS), trimmed of punctuation.
    /// Time accumulates over every id, BOS/EOS included.
    static func groups(ids: [Int32], durations: [Int32], frame: Double) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        var open: (start: Double, end: Double)?
        var t = 0.0
        for (id, d) in zip(ids, durations) {
            let start = t
            t += Double(d) * frame
            if boundaryIds.contains(id) {
                if let o = open { out.append(o) }
                open = nil
            } else if !punctuationIds.contains(id) {
                open = (open?.start ?? start, t)
            }
        }
        if let o = open { out.append(o) }
        return out
    }

    /// The words Kokoro's phonemiser splits on: runs of letters, digits and hyphens, with inner apostrophes.
    static func words(in text: String) -> [String] {
        let folded = text.replacingOccurrences(of: "’", with: "'")
        let ns = folded as NSString
        return wordRegex.matches(in: folded, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }
    private static let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}-]+(?:'[\\p{L}\\p{N}-]+)*")

    /// Pairs words with groups: one to one, else by `counts` (groups per word), else proportionally
    /// (unmatched groups go to their neighbours). Times are shifted by `offset` and kept inside the chunk.
    static func pair(_ words: [String], _ groups: [(start: Double, end: Double)], counts: [Int]?, offset: Double, duration: Double) -> [SpokenWord] {
        guard !words.isEmpty, !groups.isEmpty else { return [] }
        var owner: [Int]   // word index per group
        if groups.count == words.count {
            owner = Array(words.indices)
        } else if let counts, counts.reduce(0, +) == groups.count {
            owner = counts.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }
        } else {
            // ponytail: proportional pairing when even per-word phonemes disagree; never seen on the fixture.
            owner = groups.indices.map { $0 * words.count / groups.count }
        }
        var out: [SpokenWord] = []
        var lastOwner = -1
        for (g, w) in zip(groups, owner) {   // owner never decreases, so a word's groups are adjacent
            let start = min(max(g.start + offset, 0), duration), end = min(max(g.end + offset, start), duration)
            if w == lastOwner, let last = out.last {
                out[out.count - 1] = SpokenWord(text: last.text, start: last.start, end: end)
            } else {
                out.append(SpokenWord(text: words[w], start: start, end: end))
                lastOwner = w
            }
        }
        return out
    }
}

/// Lazily creates and initialises one Kokoro manager; concurrent callers await the same load.
private actor KokoroLoader {
    private var task: Task<KokoroAneManager, Error>?

    func manager() async throws -> KokoroAneManager {
        let task = self.task ?? Task {
            let m = KokoroAneManager(variant: .english, defaultVoice: KokoroAneConstants.defaultVoice, version: .v3)
            try await m.initialize()
            return m
        }
        self.task = task
        do { return try await task.value } catch { self.task = nil; throw error }
    }

    func drop() { task = nil }
}
