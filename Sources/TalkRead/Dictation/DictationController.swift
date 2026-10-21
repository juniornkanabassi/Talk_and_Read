// One dictation at a time: recorder -> streaming transcriber -> Cleanup -> optional Polish -> Inserter -> history.
// Ownership (PLAN decision 19): one owner from `start` until the utterance is inserted, cancelled or failed; another
// control caller gets `busy` unless it forces; the human (hotkeys, pill, GUI: caller "user") always wins.
import AppKit
import AVFoundation
import TalkReadCore

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let app: String?
}

enum DictationError: LocalizedError, Equatable {
    case busy(owner: String)
    var errorDescription: String? {
        switch self { case .busy(let owner): "Dictation is in use by \(owner)" }
    }
}

@MainActor final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording(level: Float, partial: String), transcribing, done(String), failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var history: [DictationEntry] = []
    /// The model is loading for this dictation (the pill says "Preparing…").
    @Published private(set) var preparing = false
    /// The last 11 input levels, newest last (the pill's meter).
    @Published private(set) var levels = [Float](repeating: 0, count: 11)
    /// The latest partial transcript, kept through `.transcribing`.
    private(set) var lastPartial = ""

    static let user = "user"
    /// One dictation owner at a time; other control callers get `busy` unless forced; "user" (hotkeys, GUI) always wins.
    private(set) var owner: String?
    /// No pill and no sounds (self-tests).
    var quiet = false

    let audio: DictationAudio
    let asr: DictationASR
    private let insert: (String) async -> InsertResult
    private var fileCaller: String?                       // the file-transcription slot
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var transcript: Task<String, Error>?
    private var work: Task<String?, Never>?
    private var generation = 0                            // bumped on every start/cancel; stale work changes nothing
    private var insertOnStop = true
    private var pill: DictationPill?

    init(audio: DictationAudio? = nil, asr: DictationASR? = nil, insert: ((String) async -> InsertResult)? = nil) {
        self.audio = audio ?? Recorder()
        self.asr = asr ?? Transcriber()
        self.insert = insert ?? { await Inserter.insert($0) }
        history = (try? JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: Paths.history))) ?? []
    }

    // MARK: Control (CLI/MCP pass their caller and force; hotkeys and the GUI pass "user")

    func start(caller: String, force: Bool = false) throws {
        if let current = owner {
            if current == caller { return }                       // already theirs
            guard caller == Self.user || force else { throw DictationError.busy(owner: current) }
            discard()                                             // theirs is dropped: nothing of it is inserted
        }
        owner = caller
        generation += 1
        let gen = generation
        insertOnStop = true
        levels = levels.map { _ in 0 }
        lastPartial = ""
        state = .recording(level: 0, partial: "")
        showPill()
        play("Tink")
        if !asr.isLoaded {
            preparing = true
            Task { try? await asr.load(progress: nil); preparing = false }
        }
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.feed = feed
        audio.onBuffer = { feed.yield($0) }
        audio.onLevel = { [weak self] level in self?.update(gen, level: level) }
        let asr = asr
        let onPartial: @MainActor (String) -> Void = { [weak self] text in self?.update(gen, partial: text) }
        let transcript = Task { try await asr.run(stream, partial: onPartial) }
        self.transcript = transcript
        work = Task { [weak self] in await self?.finish(gen, transcript) }
    }

    func stop(insert: Bool, caller: String, force: Bool = false) throws {
        guard let current = owner else { return }
        guard current == caller || caller == Self.user || force else { throw DictationError.busy(owner: current) }
        guard case .recording = state else { return }             // already transcribing
        insertOnStop = insert
        _ = audio.stop()
        feed?.finish()
        feed = nil
        state = .transcribing
        play("Pop")
    }

    func cancel(caller: String, force: Bool = false) throws {
        guard let current = owner else { return }
        guard current == caller || caller == Self.user || force else { throw DictationError.busy(owner: current) }
        discard()
        state = .idle
        pill?.hide()
    }

    /// Transcribes an audio file without the microphone and without typing (dictate-file). Busy while a live
    /// dictation or another file transcription runs, whoever the caller.
    func transcribe(file: URL, caller: String) async throws -> String {
        if let busy = owner ?? fileCaller { throw DictationError.busy(owner: busy) }
        fileCaller = caller                                       // reserved before the first await
        defer { fileCaller = nil }
        let samples = try await Task.detached { try Transcriber.samples(of: file) }.value
        return await clean(try await asr.transcribe(samples: samples))
    }

    func pasteLast() {
        guard let last = history.first else { return }
        Task {
            let result = await insert(last.text)
            if state == .idle, result != .inserted { show(failure: result) }
        }
    }

    /// Final text of the current or last utterance once it is typed; nil if it was cancelled or failed.
    func result() async -> String? { await work?.value }

    /// Hotkey actions; reading actions belong to the AppModel.
    func handle(_ action: HotkeyAction) {
        switch action {
        case .startRecording: try? start(caller: Self.user)
        case .stopAndInsert: if owner == Self.user { try? stop(insert: true, caller: Self.user) }
        case .cancelRecording: try? cancel(caller: Self.user)
        case .toggleRecording:
            if owner == Self.user, case .recording = state { try? stop(insert: true, caller: Self.user) }
            else { try? start(caller: Self.user) }
        case .pasteLast: pasteLast()
        case .read, .pause, .screenshot: break
        }
    }

    func unloadModel() { asr.unload() }

    // MARK: Utterance

    private func finish(_ gen: Int, _ transcript: Task<String, Error>) async -> String? {
        do {
            try await audio.start()
        } catch {
            guard gen == generation else { return nil }
            discard()
            if case RecorderError.stopped = error {               // released before the microphone delivered audio
                state = .idle
                pill?.hide()
            } else {
                show(failure: .failed(error.localizedDescription))
            }
            return nil
        }
        let raw: String
        do { raw = try await transcript.value } catch {
            guard gen == generation else { return nil }
            discard()
            show(failure: .failed("Could not transcribe: \(error.localizedDescription)"))
            return nil
        }
        let text = await clean(raw)
        guard gen == generation else { return nil }
        guard !text.isEmpty else {
            owner = nil
            show(failure: .failed("Didn't catch that"))
            return nil
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let result = insertOnStop ? await insert(text) : .inserted
        guard gen == generation else { return nil }
        owner = nil
        if result != .refusedSecure { remember(text, app: app) }   // never keep what was said into a password field
        if result == .inserted { show(done: text) } else { show(failure: result) }
        return result == .inserted ? text : nil
    }

    private func clean(_ raw: String) async -> String {
        let settings = Settings.load()
        let vocabulary = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Paths.vocabulary))) ?? [:]
        let text = Cleanup.apply(raw, vocabulary: vocabulary, removeFillers: settings.removeFillers)
        return settings.polishWithAppleIntelligence ? await Polish.polish(text) : text
    }

    /// Drops the current utterance: stops the input, abandons its transcript, releases the owner.
    private func discard() {
        generation += 1
        _ = audio.stop()
        feed?.finish()
        feed = nil
        transcript?.cancel()
        transcript = nil
        owner = nil
    }

    private func update(_ gen: Int, level: Float? = nil, partial: String? = nil) {
        guard gen == generation, case .recording(let l, let p) = state else { return }
        if let level { levels = Array(levels.dropFirst()) + [level] }
        if let partial { lastPartial = partial }
        state = .recording(level: level ?? l, partial: partial ?? p)
    }

    /// Removes one history entry and rewrites the history file.
    func delete(_ id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func remember(_ text: String, app: String?) {
        history.insert(DictationEntry(id: UUID(), date: Date(), text: text, app: app), at: 0)
        history = Array(history.prefix(Settings.load().historyLimit))
        saveHistory()
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: Paths.history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: Paths.history, options: .atomic)
    }

    // MARK: Pill and sounds

    private func show(done text: String) {
        state = .done(text)
        hideLater()
    }

    private func show(failure: InsertResult) {
        switch failure {
        case .refusedSecure: state = .failed("Not typed: password field")
        case .failed(let reason): state = .failed(reason)
        case .inserted: return
        }
        showPill()
        hideLater()
    }

    private func hideLater() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, gen == self.generation, self.owner == nil else { return }
            self.state = .idle
            self.pill?.hide()
        }
    }

    private func showPill() {
        guard !quiet else { return }
        if pill == nil { pill = DictationPill(dictation: self) }
        pill?.show()
    }

    private func play(_ name: String) {
        guard !quiet, let sound = NSSound(named: name) else { return }
        sound.volume = 0.25
        sound.play()
    }
}
