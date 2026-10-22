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
    /// The model is loading, or cancelled work is still leaving the recogniser (the pill says "Preparing…").
    @Published private(set) var preparing = false
    /// The last 11 input levels, newest last (the pill's meter).
    @Published private(set) var levels = [Float](repeating: 0, count: 11)
    /// The latest partial transcript, kept through `.transcribing`.
    private(set) var lastPartial = ""

    static let user = "user"
    /// The one admission slot for live dictation and file transcription: one owner at a time; other control callers
    /// get `busy` unless forced; "user" (hotkeys, GUI) always wins.
    private(set) var owner: String? { didSet { updateBusy() } }
    /// Recording, transcribing (live or a file), typing, draining cancelled work or loading the model (activity
    /// tracking and idle unload, Sol #24).
    @Published private(set) var isBusy = false
    /// No pill and no sounds (self-tests).
    var quiet = false

    /// Types `text`; `isCurrent` is checked inside the pasteboard transaction just before the paste.
    typealias Insert = @MainActor (_ text: String, _ targetPID: pid_t?, _ isCurrent: @MainActor () -> Bool) async -> InsertResult
    let audio: DictationAudio
    let asr: DictationASR
    private let insert: Insert
    private var fileJob: Task<String, Error>?              // set while the owner's work is a file transcription
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var transcript: Task<String, Error>?
    private var work: Task<String?, Never>?
    private var generation = 0                            // bumped on every start/cancel; stale work changes nothing
    private var insertOnStop = true
    private var inserting = 0 { didSet { updateBusy() } }  // paste-last and insert-again in flight
    /// Cancelled transcripts and file jobs still running; the next recording starts only after them (Sol #23).
    private var draining: Task<Void, Never>? { didSet { updateBusy() } }
    private var drains = 0
    private let decode: @Sendable (URL) throws -> [Float]
    private var pill: DictationPill?

    init(audio: DictationAudio? = nil, asr: DictationASR? = nil, insert: Insert? = nil,
         decode: (@Sendable (URL) throws -> [Float])? = nil) {
        self.audio = audio ?? Recorder()
        self.asr = asr ?? Transcriber()
        self.insert = insert ?? { await Inserter.insert($0, targetPID: $1, isCurrent: $2) }
        self.decode = decode ?? { try Transcriber.samples(of: $0) }
        history = (try? JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: Paths.history))) ?? []
        self.asr.onLoadingChange = { [weak self] in self?.updateBusy() }
    }

    // MARK: Control (CLI/MCP pass their caller and force; hotkeys and the GUI pass "user")

    func start(caller: String, force: Bool = false) throws {
        if let current = owner {
            if current == caller, fileJob == nil { return }       // already recording for them
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
        if !asr.isLoaded { Task { try? await asr.load(progress: nil) } }   // load alongside any drain ("Preparing…")
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.feed = feed
        audio.onBuffer = { feed.yield($0) }
        audio.onLevel = { [weak self] level in self?.update(gen, level: level) }
        let asr = asr
        let onPartial: @MainActor (String) -> Void = { [weak self] text in self?.update(gen, partial: text) }
        let transcript = Task { try await asr.run(stream, partial: onPartial) }
        self.transcript = transcript
        let drain = draining                                      // the slot is reserved; the microphone waits for it
        work = Task { [weak self] in
            await drain?.value
            return await self?.finish(gen, transcript)
        }
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

    /// Transcribes an audio file without the microphone and without typing (dictate-file). It takes the same slot as
    /// live dictation: busy while either runs, whoever the caller; the human (or a forced caller) starting a dictation
    /// cancels it, and it then throws `busy` with the new owner.
    func transcribe(file: URL, caller: String) async throws -> String {
        if let busy = owner { throw DictationError.busy(owner: busy) }
        owner = caller                                            // admitted before the first await
        let asr = asr, decode = decode
        let job = Task {
            // ponytail: the decode reads the whole file and cannot be interrupted; a takeover waits for it (the drain),
            // a few ms for a dictation clip. Make it chunked and cancellable if hour-long files ever matter.
            let samples = try await Task.detached { try decode(file) }.value
            try Task.checkCancellation()                          // taken over while decoding: never enters (Sol #23)
            return try await asr.transcribe(samples: samples)
        }
        fileJob = job
        defer { if fileJob == job { fileJob = nil; owner = nil } }   // after a takeover the slot is no longer ours
        let raw = await job.result
        guard fileJob == job else { throw DictationError.busy(owner: owner ?? Self.user) }
        return await clean(try raw.get())
    }

    func pasteLast() {
        guard let last = history.first else { return }
        Task {
            let result = await reinsert(last.id, targetPID: nil)
            if state == .idle, result != .inserted { show(failure: result) }
        }
    }

    /// Types a history entry's text again through the guarded Inserter (paste last, "Insert again"). With
    /// `targetPID`, the paste goes to that process only.
    func reinsert(_ id: UUID, targetPID: pid_t?) async -> InsertResult {
        guard let entry = history.first(where: { $0.id == id }) else { return .failed("That dictation is no longer in the history") }
        inserting += 1
        defer { inserting -= 1 }
        return await insert(entry.text, targetPID, { true })
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

    /// Frees the recogniser. False, freeing nothing, while dictation, a file, a drain or the model load still runs: the
    /// caller keeps its idle timer and tries again later (Sol #24).
    @discardableResult func unloadModel() -> Bool { !isBusy && asr.unload() }

    // MARK: Utterance

    private func finish(_ gen: Int, _ transcript: Task<String, Error>) async -> String? {
        // The microphone is asked for only by the current utterance, and only while it is still recording: a stale
        // task never starts audio (it would stop the newer utterance's input) and a stop that came first is honoured.
        guard gen == generation else { return nil }
        guard case .recording = state else { return released() }
        play("Tink")                                              // the microphone starts now, after any drain
        do {
            try await audio.start()
        } catch {
            guard gen == generation else { return nil }           // stale: the input running now is not ours to stop
            if case RecorderError.stopped = error { return released() }   // released before the microphone delivered audio
            discard()
            show(failure: .failed(error.localizedDescription))
            return nil
        }
        guard gen == generation else { return nil }               // discard() has already stopped the input
        if case .recording = state {} else { _ = audio.stop() }   // stopped while the microphone was starting
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
        // Re-checked inside the pasteboard transaction right before the paste: a cancelled utterance is never typed.
        let result = insertOnStop ? await insert(text, nil, { [weak self] in self?.generation == gen }) : .inserted
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

    /// Drops the current utterance or file transcription: stops the input, cancels its startup and transcript (or the
    /// file job), releases the owner. Called only for the current owner, so the input it stops is the current one.
    /// The cancelled backend work drains: the next recording and the idle unload wait until it has exited (Sol #23).
    private func discard() {
        generation += 1
        work?.cancel()
        _ = audio.stop()
        feed?.finish()
        feed = nil
        transcript?.cancel()
        fileJob?.cancel()
        if transcript != nil || fileJob != nil {
            drains += 1
            let id = drains, before = draining, transcript = transcript, fileJob = fileJob
            draining = Task { [weak self] in
                await before?.value
                _ = await transcript?.result
                _ = await fileJob?.result
                if self?.drains == id { self?.draining = nil }
            }
        }
        transcript = nil
        fileJob = nil
        owner = nil
    }

    /// The utterance ended before any audio: nothing to transcribe or type.
    private func released() -> String? {
        discard()
        state = .idle
        pill?.hide()
        return nil
    }

    private func updateBusy() {
        let preparing = draining != nil || asr.isLoading
        if self.preparing != preparing { self.preparing = preparing }
        let busy = owner != nil || inserting > 0 || preparing
        if isBusy != busy { isBusy = busy }
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
