// Apple's on-device recogniser (SpeechAnalyzer, macOS 26+) behind the same DictationASR interface as Parakeet: the
// no-download fallback. Uses only assets macOS already has installed; it never asks the system to download any.
import AVFoundation
import Speech

@MainActor final class AppleTranscriber: DictationASR {
    /// `.dictation` is the keyboard-dictation model (punctuation option); `.speech` is the newer long-form model.
    enum Model: String { case dictation, speech }

    let model: Model
    let locale: Locale
    /// Names and jargon to bias towards (the vocabulary's spellings), sent as the analyzer's contextual strings.
    var contextualStrings: [String] = []
    private(set) var isLoaded = false
    let isLoading = false                                   // nothing to download or load: assets are the system's
    var onLoadingChange: (() -> Void)?
    private let queue = RecogniserQueue()

    init(model: Model = .speech, locale: Locale = Locale(identifier: "en_GB")) {
        self.model = model
        self.locale = locale
    }

    /// The system already has this model for `locale` (no download needed or made).
    static func isInstalled(_ model: Model, locale: Locale = Locale(identifier: "en_GB")) async -> Bool {
        let installed = model == .speech ? await SpeechTranscriber.installedLocales : await DictationTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    func load(progress: ((Double) -> Void)?) async throws {
        guard await Self.isInstalled(model, locale: locale) else { throw AppleASRError.notInstalled(locale.identifier) }
        isLoaded = true
        progress?(1)
    }

    @discardableResult func unload() -> Bool {
        guard !queue.inUse else { return false }
        isLoaded = false
        return true
    }

    func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await queue.exclusive {
            if !isLoaded { try await load(progress: nil) }
            let (module, results) = makeModule()
            let analyzer = SpeechAnalyzer(modules: [module])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? StreamConverter.format
            try await analyzer.prepareToAnalyze(in: format)
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            let converter = format == StreamConverter.format ? nil : AVAudioConverter(from: StreamConverter.format, to: format)
            let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: inputs)
            let collect = Task { @MainActor () -> String in
                var final = ""
                for try await (text, isFinal) in results {
                    if isFinal { final += text; partial(final) } else { partial(final + text) }
                }
                return final
            }
            do {
                for await buffer in audio {
                    try Task.checkCancellation()
                    if let converter { feed.yield(AnalyzerInput(buffer: try Self.convert(buffer, converter, to: format))) }
                    else { feed.yield(AnalyzerInput(buffer: buffer)) }
                }
                try Task.checkCancellation()
                feed.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                feed.finish()
                await analyzer.cancelAndFinishNow()
                collect.cancel()
                throw error
            }
        }
    }

    /// The module plus its results as (text, isFinal) pairs.
    private func makeModule() -> (any SpeechModule, AsyncThrowingStream<(String, Bool), Error>) {
        switch model {
        case .dictation:
            let m = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            return (m, Self.pairs(m.results) { (String($0.text.characters), $0.isFinal) })
        case .speech:
            let m = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                      attributeOptions: [])
            return (m, Self.pairs(m.results) { (String($0.text.characters), $0.isFinal) })
        }
    }

    private static func pairs<S: AsyncSequence & Sendable>(_ results: S, _ map: @escaping @Sendable (S.Element) -> (String, Bool))
        -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await r in results { continuation.yield(map(r)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AppleASRError.format }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}

enum AppleASRError: LocalizedError {
    case notInstalled(String), format
    var errorDescription: String? {
        switch self {
        case .notInstalled(let locale): "Apple's speech model for \(locale) is not installed on this Mac"
        case .format: "Could not convert the audio for Apple's recogniser"
        }
    }
}
