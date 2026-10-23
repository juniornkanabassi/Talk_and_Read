// FluidAudio Kokoro-82M engine: text chunk -> 24 kHz PCM plus per-word timings taken from the model's own predicted
// durations (PLAN decision 1). Words come from walking `inputIds`/`predictedDurations` and pairing the space-separated
// groups with the words of Kokoro's normalised text.
// Runs FluidAudio's seven-stage `.legacy` chain, not `.v3`: on macOS 27.2 the v3 fast path (any chunk under 5 s of audio)
// aborts the process in MPSGraph (KokoroSourceGenerator is pinned to the GPU, "shape for TensorData is not static",
// reproduced 21 Oct), while legacy routes noise and tail to the CPU on macOS 27 and is about 80 MB instead of 380 MB.
import FluidAudio
import Foundation
import TalkReadCore

final class NeuralEngine: SpeechEngine {
    var kind: EngineKind { .neural }
    private let loader = KokoroLoader(variant: .english, voice: KokoroAneConstants.defaultVoice)
    /// The French manager (own G2P: French dictionary and CharsiuG2P); created on the first French voice, released by `unload()`.
    private let frenchLoader = KokoroLoader(variant: .french, voice: NeuralEngine.frenchVoice)
    static let frenchVoice = "ff_siwis"
    /// Voice ids that speak French: `ff_` is Kokoro's French female prefix.
    static func isFrench(_ voice: String) -> Bool { voice.hasPrefix("ff_") }

    /// The French voice's extra files (about 100 MB), downloaded with the user's consent on the Models page.
    @MainActor lazy var frenchPack: DownloadableModel = FrenchPack()

    /// Kokoro vocab ids (vocab.json, identical for the ANE and ANE-v3 English checkpoints): BOS/EOS = 0, space = 16.
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
        let english = KokoroAneConstants.englishVoices.compactMap { id -> Voice? in
            guard let (accent, gender) = kinds[String(id.prefix(2))] else { return nil }
            return Voice(id: id, name: String(id.dropFirst(3)).capitalized, accent: accent, gender: gender, engine: .neural, installed: installed, language: "en")
        }
        .sorted { ($0.accent == "British" ? 0 : 1, $0.name) < ($1.accent == "British" ? 0 : 1, $1.name) }
        // The one French pack Kokoro has; it needs the French files on top of the English chain (`frenchPack`).
        return english + [Voice(id: Self.frenchVoice, name: "Siwis", accent: "French", gender: "Female", engine: .neural,
                                installed: Self.frenchPackInstalled(), language: "fr")]
    }

    /// The French extras are on disk: the French dictionary, the CharsiuG2P pair and the `ff_siwis` pack (about 100 MB),
    /// on top of the English chain, which French shares.
    static func frenchPackInstalled() -> Bool {
        guard modelInstalled(), let root = try? TtsCacheDirectory.ensure().appendingPathComponent("Models") else { return false }
        let kokoro = root.appendingPathComponent("kokoro")
        let files = ["coremldata.bin", "model.mil", "metadata.json", "weights/weight.bin", "analytics/coremldata.bin"]
        let paths = [kokoro.appendingPathComponent(KokoroAneConstants.frenchLexiconCacheFile),
                     root.appendingPathComponent("kokoro-82m-coreml/ANE/\(frenchVoice).bin")]
            + ["MultilingualG2PEncoder.mlmodelc", "MultilingualG2PDecoder.mlmodelc"].flatMap { b in files.map { kokoro.appendingPathComponent("\(b)/\($0)") } }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The seven compiled stages and the vocab of the legacy English chain are on disk (about 80 MB).
    static func modelInstalled() -> Bool {
        guard let root = try? TtsCacheDirectory.ensure().appendingPathComponent("Models/kokoro-82m-coreml/ANE") else { return false }
        return (KokoroAneStage.allCases.map(\.bundleName) + ["vocab.json"])
            .allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    /// Loads the model (downloading it on first use) and the voice, then synthesises one word: the first prediction
    /// after a load is about a second slower, and that must not land on the reader's first chunk.
    func prepare(voice: String) async throws {
        let french = Self.isFrench(voice)
        let manager = try await (french ? frenchLoader : loader).manager()
        try await manager.initialize(preloadVoices: [voice])
        _ = try await manager.synthesizeDetailed(text: french ? "Prêt." : "Ready.", voice: voice, speed: 1)
    }

    func synthesize(_ text: String, voice: String) async throws -> SynthChunk {
        let manager = try await (Self.isFrench(voice) ? frenchLoader : loader).manager()
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: 1)
        guard !result.samples.isEmpty, result.samples.allSatisfy(\.isFinite) else { throw SpeechError.badAudio }
        let rate = Double(result.sampleRate)
        assert(abs(result.samples.count - Int(result.predictedDurations.reduce(0, +)) * Int(Self.samplesPerFrame)) < Int(Self.samplesPerFrame),
               "Kokoro audio length no longer matches its predicted durations")
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
        Task { await frenchLoader.drop() }
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
        var spans: [(word: Int, groups: [(start: Double, end: Double)])] = []
        for (g, w) in zip(groups, owner) {   // owner never decreases, so a word's groups are adjacent
            let start = min(max(g.start + offset, 0), duration), end = min(max(g.end + offset, start), duration)
            if spans.last?.word == w { spans[spans.count - 1].groups.append((start, end)) } else { spans.append((w, [(start, end)])) }
        }
        return spans.flatMap { split(words[$0.word], $0.groups) }
    }

    /// A hyphenated compound becomes one word per part ("well-known" -> "well", "known"), so every source token it
    /// covers gets its own time (Alignment keeps one source token per spoken word): each part takes its own group when
    /// the phonemiser gave one per part, else the compound's span is split by character length.
    static func split(_ word: String, _ groups: [(start: Double, end: Double)]) -> [SpokenWord] {
        let parts = word.split(separator: "-").map(String.init)
        let a = groups[0].start, b = groups[groups.count - 1].end
        guard parts.count > 1 else { return [SpokenWord(text: word, start: a, end: b)] }
        if groups.count == parts.count { return zip(parts, groups).map { SpokenWord(text: $0, start: $1.start, end: $1.end) } }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var used = 0.0
        return parts.map { part in
            let start = a + (b - a) * used / total
            used += Double(part.count)
            return SpokenWord(text: part, start: start, end: used == total ? b : a + (b - a) * used / total)
        }
    }
}

/// The French extras of Kokoro (dictionary, G2P model, `ff_siwis` pack), fetched by FluidAudio's own downloader.
@MainActor private final class FrenchPack: DownloadableModel {
    let title = "French voice (Kokoro)"
    let modelMegabytes = 100
    var isModelInstalled: Bool { NeuralEngine.frenchPackInstalled() }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Weights by size; the shared English chain (about 80 MB) only counts when this Mac has none yet.
        let chain = NeuralEngine.modelInstalled() ? 0.0 : 0.45
        let total = chain + 0.55
        var done = 0.0
        func stage(_ weight: Double, _ run: (@escaping ProgressHandler) async throws -> Void) async throws {
            let start = done
            try await run { p in progress((start + weight * p.fractionCompleted) / total) }
            done += weight
            progress(done / total)
        }
        var repo = URL(fileURLWithPath: "/")
        try await stage(chain) { repo = try await KokoroAneResourceDownloader.ensureModels(variant: .french, progressHandler: $0) }
        try await stage(0.1) { _ in _ = try await KokoroAneResourceDownloader.ensureLexiconCache(KokoroAneConstants.frenchLexiconCacheFile) }
        try await stage(0.4) { try await KokoroAneResourceDownloader.ensureMultilingualG2PAssets(progressHandler: $0) }
        try await stage(0.05) { _ in _ = try await KokoroAneResourceDownloader.ensureVoicePack(NeuralEngine.frenchVoice, repoDirectory: repo, variant: .french) }
    }
}

/// Lazily creates and initialises one Kokoro manager; concurrent callers await the same load.
private actor KokoroLoader {
    private var task: Task<KokoroAneManager, Error>?
    private let variant: KokoroAneVariant
    private let voice: String

    init(variant: KokoroAneVariant, voice: String) { self.variant = variant; self.voice = voice }

    func manager() async throws -> KokoroAneManager {
        let (variant, voice) = (self.variant, self.voice)
        let task = self.task ?? Task {
            let m = KokoroAneManager(variant: variant, defaultVoice: voice, version: .legacy)
            try await m.initialize()
            return m
        }
        self.task = task
        do { return try await task.value } catch { self.task = nil; throw error }
    }

    func drop() { task = nil }
}
