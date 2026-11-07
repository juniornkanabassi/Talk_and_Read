// Deterministic cancellation/ownership checks. Run with fresh, unseeded HOME and TALKREAD_HOME.
import Foundation
import FluidAudio
import TalkReadCore

@MainActor enum ModelDownloadSelfTest {
    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        if CommandLine.arguments.contains("--corrupt-cache") { return await corruptCache() }
        guard !NeuralEngine.modelInstalled(), !Transcriber.isDownloaded else {
            print("FAIL model-downloads: use an unseeded disposable HOME and TALKREAD_HOME")
            return 2
        }
        let model = AppModel.shared
        let oldEngines = model.engines
        let oldVoice = model.downloadVoiceFiles, oldDictation = model.downloadDictationFiles
        defer { model.engines = oldEngines; model.downloadVoiceFiles = oldVoice; model.downloadDictationFiles = oldDictation }
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ text: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL") \(text)") }
        let fake = DownloadFixture()
        model.engines = Engines(neural: SilentEngine(kind: .neural), system: SilentEngine(kind: .system), qwen: fake)
        await model.loadVoices()
        let marker = Paths.dataRoot.appendingPathComponent("existing-model.txt")
        try? FileManager.default.createDirectory(at: Paths.dataRoot, withIntermediateDirectories: true)
        try? Data("installed bytes".utf8).write(to: marker)
        func row() -> ModelState? { model.models.first { $0.title == fake.title }?.state }

        model.download(fake.title)
        let optionalStarted = await wait { fake.operations.count == 1 }
        check(optionalStarted, "optional download starts once")
        guard optionalStarted else { return 1 }
        model.cancelDownload(fake.title)
        fake.operations[0].progress(0.9)
        model.download(fake.title)
        await settle()
        check(fake.operations.count == 1, "retry waits for cancelled operation to drain")
        check(row() == .downloading(progress: 0), "cancelled progress cannot update the row")
        fake.operations[0].finish()
        check(await wait { row() == .missing(megabytes: fake.modelMegabytes) }, "cancelled optional download returns to missing")
        check((try? Data(contentsOf: marker)) == Data("installed bytes".utf8), "cancellation preserves completed model bytes")

        model.download(fake.title)
        let optionalRetried = await wait { fake.operations.count == 2 }
        check(optionalRetried, "optional download can retry after draining")
        guard optionalRetried else { return 1 }
        fake.operations[0].progress(0.99)
        await settle()
        check(row() == .downloading(progress: 0), "old attempt cannot overwrite a retry")
        fake.operations[1].progress(0.4)
        check(await wait { row() == .downloading(progress: 0.4) }, "active attempt reports progress")
        fake.isModelInstalled = true
        fake.operations[1].finish()
        check(await wait { row() == .ready }, "completed optional model remains ready")
        model.cancelDownload(fake.title)
        check(row() == .ready, "cancel does not remove a completed model")

        var voices: [PausedDownload] = [], dictationCalls = 0
        model.downloadVoiceFiles = { _, report in
            let operation = PausedDownload(progress: report)
            voices.append(operation)
            await operation.run()
        }
        model.downloadDictationFiles = { _, _ in dictationCalls += 1 }
        model.downloadModels()
        let defaultStarted = await wait { voices.count == 1 }
        check(defaultStarted, "default download uses its owned operation")
        guard defaultStarted else { return 1 }
        model.cancelModelDownload()
        model.downloadModels()
        voices[0].progress(0.99)
        await settle()
        check(voices.count == 1 && model.downloadTask != nil, "default retry waits for cancellation drain")
        check(model.voiceModel == .downloading(progress: 0), "cancelled default progress is ignored")
        voices[0].finish()
        check(await wait { model.downloadTask == nil }, "default cancellation releases its task after drain")
        check(dictationCalls == 0 && model.voiceModel == .missing(megabytes: AppModel.voiceMegabytes), "default cancel stops before the next model")
        model.downloadModels()
        let defaultRetried = await wait { voices.count == 2 }
        check(defaultRetried, "default group can retry")
        guard defaultRetried else { return 1 }
        voices[0].progress(0.95)
        await settle()
        check(model.voiceModel == .downloading(progress: 0), "old default progress cannot overwrite retry")
        voices[1].finish()
        check(await wait { model.downloadTask == nil }, "default group completes without a stuck task")
        check(dictationCalls == 1, "default group advances only after the active voice finishes")

        do {
            let root = Paths.dataRoot.appendingPathComponent("transfer", isDirectory: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            let target = root.appendingPathComponent("model", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("weights.bin")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 32 * 1024 * 1024)
            try handle.close()
            let preserved = target.appendingPathComponent("existing.bin")
            try Data("keep".utf8).write(to: preserved)
            let cancellation = TransferCancellation()
            let transfer = Task {
                try await ModelDownload.fetch([("weights.bin", 32 * 1024 * 1024)], from: source, into: target) { _ in cancellation.cancel() }
            }
            cancellation.set(transfer)
            let result = await transfer.result
            let failed: Bool
            if case .failure = result { failed = true } else { failed = false }
            check(cancellation.observed && failed, "real URLSession transfer observes cancellation")
            check((try? Data(contentsOf: preserved)) == Data("keep".utf8), "cancelled transfer preserves installed folder")
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".model.partial").path), "cancelled transfer removes staging folder")
            try FileManager.default.removeItem(at: root)
        } catch { check(false, "transfer fixture: \(error)") }
        try? FileManager.default.removeItem(at: marker)
        print("model-downloads: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }

    /// Run separately on a seeded disposable user: the valid baseline makes this a real parser regression check.
    private static func corruptCache() async -> Int32 {
        guard let user = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              TalkReadMain.isDisposableHome(user) else { return 2 }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(Repo.parakeetUnified.folderName)")
        let vocab = directory.appendingPathComponent(ModelNames.ParakeetUnified.vocab)
        let userPath = URL(fileURLWithPath: user).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard vocab.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(userPath),
              let original = try? Data(contentsOf: vocab) else {
            print("FAIL model-cache-validation: seeded disposable vocabulary missing")
            return 2
        }
        let offline = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = offline; try? original.write(to: vocab, options: .atomic) }
        do {
            try await Transcriber.downloadFiles(includeBoosting: false, progress: { _ in })
            print("PASS seeded model validates before corruption")
            try Data("{".utf8).write(to: vocab, options: .atomic)
            do {
                try await Transcriber.downloadFiles(includeBoosting: false, progress: { _ in })
                print("FAIL corrupt vocabulary was accepted")
                return 1
            } catch {
                guard FileManager.default.fileExists(atPath: vocab.path) else {
                    print("FAIL offline validation deleted the cache")
                    return 1
                }
                print("PASS corrupt vocabulary is rejected without deleting the offline cache")
            }
            try original.write(to: vocab, options: .atomic)
            try await Transcriber.downloadFiles(includeBoosting: false, progress: { _ in })
            print("PASS restored vocabulary validates")
            print("model-cache-validation: 3/3 passed")
            return 0
        } catch {
            print("FAIL model-cache-validation: \(error)")
            return 1
        }
    }

    private static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
}

@MainActor private final class PausedDownload {
    let progress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(progress: @escaping (Double) -> Void) { self.progress = progress }
    func run() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor private final class DownloadFixture: SpeechEngine, DownloadableModel {
    let kind = EngineKind.qwen
    let title = "Cancellation fixture"
    let modelMegabytes = 32
    var isModelInstalled = false
    var operations: [PausedDownload] = []
    func voices() async -> [Voice] { [] }
    func prepare(voice: String) async throws {}
    func synthesize(_ text: String, voice: String) async throws -> SynthChunk { throw SpeechError.badAudio }
    nonisolated func unload() {}
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let operation = PausedDownload(progress: progress)
        operations.append(operation)
        await operation.run()
        try Task.checkCancellation()
    }
}

private final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var didObserve = false
    var observed: Bool { lock.withLock { didObserve } }
    func set(_ value: Task<Void, Error>) {
        if lock.withLock({ task = value; return didObserve }) { value.cancel() }
    }
    func cancel() {
        let value = lock.withLock { didObserve = true; return task }
        value?.cancel()
    }
}
