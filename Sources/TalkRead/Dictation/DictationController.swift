// One dictation at a time: recorder -> streaming transcriber -> Paragraphs.split -> Cleanup -> Paragraphs.tidy -> optional Polish -> Inserter -> history.
// Ownership (PLAN decision 19): one owner from `start` until the utterance is inserted, cancelled or failed; another
// control caller gets `busy` unless it forces; the human (hotkeys, pill, GUI: caller "user") always wins.
import AppKit
import AVFoundation
import TalkReadCore

extension DictationController.State {
    /// Done or failed: the pill shows the result (and Copy when there is something to copy).
    var showsResult: Bool { if case .done = self { true } else if case .failed = self { true } else { false } }
}

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let app: String?
    /// The frontmost app's bundle identifier when it was said (nil in older histories; the Home list uses it for the app icon).
    var bundleID: String? = nil
}

enum DictationError: LocalizedError, Equatable {
    case busy(owner: String)
    var errorDescription: String? {
        switch self { case .busy(let owner): "Dictation is in use by \(owner)" }
    }
}

@MainActor final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording(level: Float, partial: String), transcribing, done(String), failed(String) }
    @Published private(set) var state: State = .idle {
        didSet { if !state.showsResult { copyable = nil; copied = false } }
    }
    @Published private(set) var history: [DictationEntry] = []
    /// The model is loading, or cancelled work is still leaving the recogniser (the pill says "Preparing…").
    @Published private(set) var preparing = false
    /// What the pill's Copy button copies: the dictation it shows once done but not confirmed to have landed, or not typed
    /// but kept in the history. nil otherwise (a confirmed paste needs no Copy), and never for a password field.
    @Published private(set) var copyable: String?
    /// Copy was just pressed (the button says "Copied" for a moment).
    @Published private(set) var copied = false
    /// How long a confirmed, an unconfirmed (`done`) and a failed pill stay, and how often a hovered pill checks again (seconds; the self-test
    /// shortens them). The pointer over the pill holds it.
    var holdSeconds = (confirmed: 1.5, done: 5.0, failed: 8.0, recheck: 0.5)
    /// The pointer is over the pill (hover pauses its hide); the self-test swaps it.
    lazy var pointerOverPill: () -> Bool = { [weak self] in self?.pill?.containsPointer ?? false }
    /// The last 11 input levels, newest last (the pill's meter).
    @Published private(set) var levels = [Float](repeating: 0, count: 11)
    /// The latest partial transcript, kept through `.transcribing`.
    private(set) var lastPartial = ""
    /// Settings.dictationMicrophone: the input for the next recording (nil = system default).
    var microphoneUID: String?
    /// Set while recording when the saved microphone is not connected and the default is used instead (the pill shows it).
    @Published private(set) var micNotice: String?

    static let user = "user"
    /// The one admission slot for live dictation and file transcription: one owner at a time; other control callers
    /// get `busy` unless forced; "user" (hotkeys, GUI) always wins.
    private(set) var owner: String? { didSet { updateBusy() } }
    /// Recording, transcribing (live or a file), typing, draining cancelled work or loading the model (activity
    /// tracking and idle unload, Sol #24).
    @Published private(set) var isBusy = false
    /// No pill and no sounds (self-tests).
    var quiet = false
    /// Use Apple's on-device recogniser instead of Parakeet (lead: a Settings choice; default Parakeet). Apple's is also
    /// used, with no setting, while Parakeet's model is not on the Mac, so dictation works before any download.
    var preferApple = false
    let apple = AppleTranscriber()
    private var appleInstalled = false
    /// Learn from the user's corrections after a dictation (opt-in, off by default; lead: a Settings toggle).
    var learnCorrections = false
    /// Respell American spellings the British dictionary rejects (Junior writes British English; lead: a Settings row).
    var britishSpelling = true
    /// Re-spellings seen in two dictations, offered for the vocabulary (the pill offers the first one).
    @Published private(set) var suggestions: [AutoLearn.Correction] = []
    /// The suggestion the pill is offering, once each (ignored ones stay in `suggestions`).
    @Published private(set) var offering: AutoLearn.Correction?
    private var offered: Set<AutoLearn.Correction> = []
    private var watcher: Task<Void, Never>?

    /// Types `text`; `isCurrent` is checked inside the pasteboard transaction just before the paste. `requireField`: the
    /// end of a dictation, when nothing may be focused (paste last and Insert again are deliberate, so they paste anyway).
    typealias Insert = @MainActor (_ text: String, _ targetPID: pid_t?, _ requireField: Bool, _ isCurrent: @MainActor () -> Bool) async -> InsertResult
    let audio: DictationAudio
    let asr: DictationASR
    private let insert: Insert
    private var fileJob: Task<Transcript, Error>?           // set while the owner's work is a file transcription
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var transcript: Task<Transcript, Error>?
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
        self.insert = insert ?? { await Inserter.insert($0, targetPID: $1, requireField: $2, isCurrent: $3) }
        self.decode = decode ?? { try Transcriber.samples(of: $0) }
        history = (try? JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: Paths.history))) ?? []
        self.asr.onLoadingChange = { [weak self] in self?.updateBusy() }
        Task { [weak self] in
            let installed = await AppleTranscriber.isInstalled(.speech)
            self?.appleInstalled = installed
        }
    }

    /// The recogniser for the next utterance: Parakeet, unless Apple's is preferred, or Parakeet's model is not on the
    /// Mac yet and Apple's is installed (no download needed).
    private func recogniser() -> DictationASR {
        guard asr is Transcriber, appleInstalled else { return asr }
        let parakeetReady = asr.isLoaded || asr.isLoading || Transcriber.isDownloaded
        guard preferApple || !parakeetReady else { return asr }
        apple.contextualStrings = Cleanup.terms(vocabulary())
        return apple
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
        watcher?.cancel()                                         // a new dictation ends the last one's watch
        offering = nil
        pillToken += 1                                            // the last result's hide no longer applies
        micNotice = nil
        insertOnStop = true
        levels = levels.map { _ in 0 }
        lastPartial = ""
        state = .recording(level: 0, partial: "")
        showPill()
        let asr = recogniser()
        if !asr.isLoaded { Task { try? await asr.load(progress: nil) } }   // load alongside any drain ("Preparing…")
        let (stream, feed) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.feed = feed
        audio.onBuffer = { feed.yield($0) }
        audio.onLevel = { [weak self] level in self?.update(gen, level: level) }
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
        feed?.finish()                                            // the recogniser finishes while the input stops
        feed = nil
        _ = audio.stop()
        micNotice = nil
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

    /// The pill's ✕: cancels a dictation in progress, or closes the result it shows.
    func dismiss() {
        if owner != nil { try? cancel(caller: Self.user); return }
        pillToken += 1
        state = .idle
        pill?.hide()
    }

    /// The pill's Copy: the dictation goes on the clipboard the inserter uses (the self-test swaps in a private one).
    /// Queued as a transaction, so it lands after any running capture or paste has restored and a capture waiting for an
    /// app's copy never takes it for that copy (Sol verification 15 #2); written without `gate.write`, so its own restore
    /// leaves it, a deliberate copy, in place. "Copied" only once it is written (Sol verification 16). The returned task
    /// finishes then.
    @discardableResult func copyResult() -> Task<Void, Never>? {
        guard let text = copyable else { return nil }
        let gate = Inserter.gate, token = pillToken
        return Task { [weak self] in
            let wrote = await gate.transaction { () -> Bool in
                guard gate.prepareToChange() != nil else { return false }   // quitting: change nothing
                gate.pasteboard.clearContents()
                return gate.pasteboard.setString(text, forType: .string)
            }
            guard wrote, let self, self.pillToken == token else { return }
            self.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.pillToken == token { self?.copied = false }
            }
        }
    }

    /// Transcribes an audio file without the microphone and without typing (dictate-file). It takes the same slot as
    /// live dictation: busy while either runs, whoever the caller; the human (or a forced caller) starting a dictation
    /// cancels it, and it then throws `busy` with the new owner.
    func transcribe(file: URL, caller: String) async throws -> String {
        if let busy = owner { throw DictationError.busy(owner: busy) }
        owner = caller                                            // admitted before the first await
        let asr = recogniser(), decode = decode
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
            if state == .idle, !result.landed { show(failure: result, text: last.text) }
        }
    }

    /// Types a history entry's text again through the guarded Inserter (paste last, "Insert again"). With
    /// `targetPID`, the paste goes to that process only.
    func reinsert(_ id: UUID, targetPID: pid_t?) async -> InsertResult {
        guard let entry = history.first(where: { $0.id == id }) else { return .failed("That dictation is no longer in the history") }
        inserting += 1
        defer { inserting -= 1 }
        return await insert(entry.text, targetPID, false, { true })
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
        case .read, .pause, .screenshot, .increaseSpeed, .decreaseSpeed, .skipBackward, .skipForward: break
        }
    }

    /// Frees the recogniser. False, freeing nothing, while dictation, a file, a drain or the model load still runs: the
    /// caller keeps its idle timer and tries again later (Sol #24).
    @discardableResult func unloadModel() -> Bool { !isBusy && asr.unload() }

    // MARK: Utterance

    private func finish(_ gen: Int, _ transcript: Task<Transcript, Error>) async -> String? {
        // The microphone is asked for only by the current utterance, and only while it is still recording: a stale
        // task never starts audio (it would stop the newer utterance's input) and a stop that came first is honoured.
        guard gen == generation else { return nil }
        guard case .recording = state else { return released() }
        play("Tink")                                              // the microphone starts now, after any drain
        let mic = Microphone.resolve(microphoneUID, in: Microphone.inputs())   // decided per recording, never mid-recording
        micNotice = mic.notice
        (audio as? Recorder)?.microphoneUID = mic.device?.uid
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
        if let notice = audio.fallbackNotice { micNotice = notice }   // the chosen mic went away after it was resolved
        if case .recording = state {} else { _ = audio.stop() }   // stopped while the microphone was starting
        let raw: Transcript
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.localizedName, bundleID = frontmost?.bundleIdentifier
        // Re-checked inside the pasteboard transaction right before the paste: a cancelled utterance is never typed.
        let result = insertOnStop ? await insert(text, nil, true, { [weak self] in self?.generation == gen }) : .inserted(confirmed: false)
        guard gen == generation else { return nil }
        owner = nil
        if result != .refusedSecure { remember(text, app: app, bundleID: bundleID) }   // never keep what was said into a password field
        if case .inserted(let confirmed) = result { show(done: text, confirmed: confirmed) } else { show(failure: result, text: text) }
        if result.landed, insertOnStop, learnCorrections {
            watcher = Task { [weak self] in
                let found = await CorrectionWatcher.watch(text: text)
                self?.learn(found)
            }
        }
        return result.landed ? text : nil
    }

    private func clean(_ raw: Transcript) async -> String {
        let settings = Settings.load()
        // Paragraphs are chosen on the raw text, where the pauses line up with its sentences; Cleanup keeps the breaks.
        let spoken = settings.paragraphs ? Paragraphs.split(raw.text, pauses: raw.pauses) : raw.text
        var text = Cleanup.apply(spoken, vocabulary: vocabulary(), removeFillers: settings.removeFillers, isWord: Self.isCommonWord)
        if britishSpelling { text = BritishSpelling.apply(text) }
        if settings.paragraphs { text = Paragraphs.tidy(text) }
        return settings.polishWithAppleIntelligence ? await Polish.polish(text) : text
    }

    /// In the British or American dictionary in lower case, so names ("Donahue", "Nevis") are not common words: near-miss
    /// vocabulary correction leaves common words alone (Sol inspection 4 #4).
    static func isCommonWord(_ word: String) -> Bool {
        ["en_GB", "en_US"].contains {
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0, language: $0, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    private func vocabulary() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Paths.vocabulary))) ?? [:]
    }

    // MARK: Learning from corrections (opt-in)

    private static var learntFile: URL { Paths.dataRoot.appendingPathComponent("learned-corrections.json") }

    /// Counts the corrections of one dictation; those seen twice and not yet in the vocabulary are offered.
    func learn(_ found: [AutoLearn.Correction]) {
        guard !found.isEmpty else { return }
        var counts = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: Self.learntFile))) ?? [:]
        let ready = AutoLearn.record(found, in: &counts)
        try? JSONEncoder().encode(counts).write(to: Self.learntFile, options: .atomic)
        let known = vocabulary()
        let new = ready.filter { known[$0.heard.lowercased()] != $0.typed && !suggestions.contains($0) }
        guard !new.isEmpty else { return }
        suggestions += new
        if owner == nil, state == .idle { offerOrHide() }          // else when this dictation's result has gone
    }

    /// While idle: the pill offers the next suggestion not yet offered for 8 s, or hides.
    private func offerOrHide() {
        offering = quiet ? nil : suggestions.first { !offered.contains($0) }
        guard let shown = offering else { pill?.hide(); return }
        offered.insert(shown)
        showPill()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, gen == self.generation, self.owner == nil, self.offering == shown else { return }
            self.offering = nil                                   // ignored: still listed in `suggestions`
            self.pill?.hide()
        }
    }

    /// Adds the suggestion to the vocabulary ("heard as" → "type instead").
    func acceptSuggestion(_ c: AutoLearn.Correction) throws {
        var map = vocabulary()
        map[c.heard.lowercased()] = c.typed
        do {
            try FileManager.default.createDirectory(at: Paths.vocabulary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(map).write(to: Paths.vocabulary, options: .atomic)
        } catch { throw AppError(code: "failed", message: "Could not save: \(error.localizedDescription)") }
        dismissSuggestion(c)
    }

    func dismissSuggestion(_ c: AutoLearn.Correction) {
        suggestions.removeAll { $0 == c }
        if offering == c { offering = nil }
        if owner == nil, state == .idle { offerOrHide() }
    }

    /// Drops the current utterance or file transcription: stops the input, cancels its startup and transcript (or the
    /// file job), releases the owner. Called only for the current owner, so the input it stops is the current one.
    /// The cancelled backend work drains: the next recording and the idle unload wait until it has exited (Sol #23).
    private func discard() {
        generation += 1
        micNotice = nil
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

    private func remember(_ text: String, app: String?, bundleID: String?) {
        history.insert(DictationEntry(id: UUID(), date: Date(), text: text, app: app, bundleID: bundleID), at: 0)
        history = Array(history.prefix(Settings.load().historyLimit))
        saveHistory()
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: Paths.history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: Paths.history, options: .atomic)
    }

    // MARK: Pill and sounds

    /// `confirmed`: the focus was known to take the text, so the pill shows the words briefly with no Copy and no tip;
    /// otherwise (the app did not say, or nothing was typed) Copy and the tip stay for longer.
    private func show(done text: String, confirmed: Bool) {
        state = .done(text)
        copyable = confirmed ? nil : text
        hideLater(after: confirmed ? holdSeconds.confirmed : holdSeconds.done)
    }

    /// `text`: what was said, kept in the history, so Copy offers it (never after a password field refused it).
    private func show(failure: InsertResult, text: String? = nil) {
        switch failure {
        case .refusedSecure: state = .failed(Inserter.refusal()); copyable = nil
        case .failed(let reason): state = .failed(reason); copyable = text
        case .inserted: return
        }
        showPill()
        hideLater(after: holdSeconds.failed)
    }

    /// Bumped by every result shown, a new dictation and the ✕: a stale hide or "Copied" reset does nothing.
    private var pillToken = 0

    /// The result goes after `seconds`; while the pointer is over the pill, or a file transcription holds the slot (a
    /// new dictation bumps the token instead), it waits, checking again every `holdSeconds.recheck` (Sol verification 15 #3).
    private func hideLater(after seconds: Double) {
        pillToken += 1
        let token = pillToken
        func fire(after seconds: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, token == self.pillToken else { return }
                if self.owner != nil || self.pointerOverPill() { return fire(after: self.holdSeconds.recheck) }
                self.state = .idle
                self.offerOrHide()
            }
        }
        fire(after: seconds)
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
