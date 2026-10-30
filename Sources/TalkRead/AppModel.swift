// @MainActor observable app state; the UI binds only to these members, the control handler routes through them. Owned by WP7.
import AppKit
import Combine
import Foundation
import PDFKit
import TalkReadCore

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    /// pdf|text|markdown|rtf|docx|html|epub|web|pasted
    var kind: String
    /// Copy under Documents/.
    var fileName: String
    var added: Date
    /// Token index of the reading position.
    var position: Int
}

struct ReadEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let app: String?
    /// First 5,000 characters.
    let text: String
    /// The app's bundle identifier when it was read (nil in older histories and for reads started inside Talk & Read).
    var bundleID: String? = nil
}

/// Reads started inside Talk & Read (the Home editor) carry no app name; the history shows these.
let ownAppName = "Talk & Read"

extension ReadEntry {
    var historyItem: HistoryItem {
        HistoryItem(id: id, kind: .read, date: date, app: app ?? ownAppName,
                    bundleID: app == nil ? Bundle.main.bundleIdentifier : bundleID, text: text)
    }
}

extension DictationEntry {
    var historyItem: HistoryItem { HistoryItem(id: id, kind: .dictated, date: date, app: app, bundleID: bundleID, text: text) }
}

enum PermissionKind: String { case accessibility, microphone, screenRecording }

struct Permissions: Equatable {
    var accessibility = false
    var microphone = false
    var screenRecording = false
}

enum ModelState: Equatable { case missing(megabytes: Int), downloading(progress: Double), ready, failed(String) }

/// One of `Engines.downloadables()` as the UI shows it (Models page, the Voices page's download row).
struct ModelRow: Identifiable, Equatable {
    let title: String
    let megabytes: Int
    let state: ModelState
    var id: String { title }
}

extension EngineKind {
    /// The model's name in pickers and `talkread voices`.
    var modelName: String {
        switch self {
        case .neural: "Kokoro"
        case .qwen: "Qwen3"
        case .breeze: "Breeze"
        case .system: "System"
        }
    }
    /// Qwen3 and Breeze: gigabytes while loaded, so they load only while chosen and fall back to Kokoro when slow.
    var isLarge: Bool { self == .qwen || self == .breeze }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: Settings { didSet { settingsDidChange(from: oldValue) } }
    @Published private(set) var voices: [Voice] = []
    @Published private(set) var session: ReadSession?
    let dictation = DictationController()
    @Published private(set) var library: [LibraryItem]
    @Published private(set) var recentReads: [ReadEntry]
    @Published private(set) var permissions = Permissions.current()
    @Published private(set) var voiceModel: ModelState = .missing(megabytes: AppModel.voiceMegabytes)
    @Published private(set) var dictationModel: ModelState = .missing(megabytes: AppModel.dictationMegabytes)
    /// Additive (0.3.0): every `engines.downloadables()` entry (Qwen3, Parakeet v3, the Kokoro French pack) with its state.
    @Published private(set) var models: [ModelRow] = []

    /// Additive (not in ESSENTIALS): true while the shortcut recorder is listening, so the global hotkeys stand down.
    @Published var hotkeysPaused = false
    /// Bumped when the control socket changes vocabulary.json or pronunciations.json, so an open editor reloads them.
    @Published private(set) var wordListsRevision = 0

    /// Replaceable so the control self-test can read with a silent engine.
    var engines = Engines()
    private(set) var insertingAgain = false
    var insertAgainTarget: () async -> NSRunningApplication? = { await AppModel.otherFrontmostApp(within: 1) }
    /// Replaceable so the control self-test can remove an item during tokenisation.
    var documentWordCount: (String) async -> Int = { text in
        await Task.detached { TextKit.tokenize(text).count }.value
    }
    /// PLAN decision 16: who owns the current read. Reserved synchronously when a read is requested, held through
    /// preparing, playing and paused, released at finished, failed or stopped.
    var owner: (caller: String, sessionID: UUID)?
    /// What the status command reports about the current read (the voice is the session's `effectiveVoice`).
    /// Published so a speed shown from `activeSpeed` refreshes when only the live read's rate changes (a paused preview).
    @Published private(set) var sessionInfo = (source: "", rate: Float(1), item: UUID?.none)
    private(set) var downloadTask: Task<Void, Never>?
    /// Optional downloads in flight or failed, by title; the rest show installed or missing.
    private var downloadStates: [String: ModelState] = [:]
    /// The user left Qwen3 or Breeze while something was reading: free it when the read ends (PLAN 0.3.0 rev. 5, V7).
    private var modelSwitchPending = false

    private var highlighter: Highlighter?
    /// The app whose AX wake a running Highlighter will put back when the read ends (E8). Nil with highlighting off:
    /// then nobody will, so whoever woke it must.
    var highlightedPID: pid_t? { highlighter == nil ? nil : liveSession?.capture?.pid }
    private var sessionWatch: AnyCancellable?
    private var dictationWatch: AnyCancellable?
    private var readState: ReadSession.State?
    private var dictating = false
    private var modelsWarm = false
    private var activity: NSObjectProtocol?
    private var unloadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Idle time before the models unload; nil = `settings.unloadAfterMinutes` (the control self-test shortens it).
    var unloadDelay: Duration?
    var unloadPending: Bool { unloadTask != nil }

    nonisolated static let voiceMegabytes = 90, dictationMegabytes = 590
    /// FluidAudio's macOS TTS cache (`TtsCacheDirectory`); watched only for download progress.
    nonisolated private static let voiceModelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml", isDirectory: true)

    private init() {
        settings = Settings.load()
        library = Self.loadJSON(Paths.library) ?? []
        recentReads = Self.loadJSON(Paths.reads) ?? []
        refreshModelStates()
        applyDictationSettings()
        // Recording, transcribing (live or a file) or typing: one flag from the dictation's admission slot (Sol #16).
        dictationWatch = dictation.$isBusy.sink { [weak self] busy in
            self?.dictating = busy
            self?.updateActivity()
        }
    }

    // MARK: Settings

    /// The Dictation settings live on the controller (V-G).
    private func applyDictationSettings() {
        dictation.preferApple = settings.dictationEngine == "apple"
        dictation.learnCorrections = settings.learnCorrections
        dictation.britishSpelling = settings.britishSpelling
        dictation.historyLimit = settings.historyLimit
        dictation.languages = settings.dictationLanguages
        dictation.microphoneUID = settings.dictationMicrophone
    }

    private func settingsDidChange(from old: Settings) {
        guard settings != old else { return }
        applyDictationSettings()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
        if settings.voiceID != old.voiceID || settings.frenchVoiceID != old.frenchVoiceID { voiceChoiceChanged(from: old) }
        // Highlight switched off mid-read: the overlay goes now, and its stop restores any accessibility wake (E8).
        if old.showHighlight, !settings.showHighlight { highlighter?.stop(); highlighter = nil }
        // A new voice applies to the next read (V1, PLAN 0.3.0 rev. 4); speed is instant.
        if settings.speed != old.speed, let s = liveSession { sessionInfo.rate = settings.speed; s.setRate(settings.speed) }
    }

    /// Leaving Qwen3 or Breeze frees it once nothing reads; otherwise the new choice is loaded ahead of its first read.
    private func voiceChoiceChanged(from old: Settings) {
        func large(_ s: Settings) -> Set<EngineKind> {
            Set([s.voiceID, s.frenchVoiceID].compactMap { id in voices.first { $0.id == id }?.engine }.filter(\.isLarge))
        }
        if !large(old).isSubset(of: large(settings)) { modelSwitchPending = true }
        guard liveSession == nil else { return }
        if modelSwitchPending { return freeUnchosenModels() }
        // ponytail: no warm-up right after an unload (the unload and a prepare race inside the engine); the next read loads it.
        warm(settings.voiceID != old.voiceID ? voice(for: settings.voiceID) : voice(for: settings.frenchVoiceID, language: "fr"))
    }

    private func freeUnchosenModels() {
        // The delivered read state, not `liveSession`: a session's @Published state reaches us before it is stored, so
        // at a natural finish the session still says playing and the switch would wait for the idle timer (Sol
        // inspection 5 #2).
        guard modelSwitchPending, !(readState.map { [ReadSession.State.preparing, .playing, .paused].contains($0) } ?? false) else { return }
        // Busy (a warm-up, a chunk or a cancelled one draining): try again the moment the MLX queue is free, not at the
        // idle timer, which may be many minutes away with gigabytes still loaded (Sol plan review 0.4.0 #5).
        guard !engines.isBusy else { return engines.whenIdle { Task { @MainActor [weak self] in self?.freeUnchosenModels() } } }
        modelSwitchPending = false
        engines.unloadAll()   // the dictation model stays for the idle timer
        Log.write("voice model switched: speech models unloaded")
    }

    /// Writes the settings now (skipping the 300 ms debounce); also called at quit.
    func saveSettings() {
        saveTask?.cancel()
        do { try settings.save() } catch { Log.write("settings save failed: \(error)") }
    }

    // MARK: Voices and models

    func loadVoices() async {
        voices = await engines.allVoices()
        refreshModelStates()
    }

    /// At launch: loads the English voice in the background when it is Kokoro and installed, so the first read starts
    /// quickly (a cold load takes 8–14 s); the idle timer unloads it again.
    // ponytail: Qwen3 is not loaded at login (4–5 GB); it loads when picked or at its first read.
    func warmUp() {
        Player.warmOutput()
        let v = voice(for: settings.voiceID)
        if v.engine == .neural { warm(v) }
    }

    /// Loads a chosen voice ahead of its first read (PLAN 0.3.0 decision 3); the idle timer frees it again.
    private func warm(_ v: Voice) {
        guard v.installed, v.engine != .system else { return }
        // Above the speed its engine sustains a read starts on Kokoro (ReadSession.start), so warm Kokoro, not the model;
        // a read at or below the limit loads the model itself. Speed changes load and unload nothing.
        if let limit = engines.engine(for: v).keepsUpTo, settings.speed > limit {
            if let k = kokoroFallback(v.language) { warm(k) }
            return
        }
        modelsWarm = true
        updateActivity()
        let engine = engines.engine(for: v)
        Task {
            do { try await engine.prepare(voice: v.id) } catch { Log.write("voice warm-up failed: \(error)") }
        }
    }

    /// The voice that can read `id` now (PLAN 0.3.0 rev. 8): itself once installed, else the same-language Kokoro voice,
    /// else that language's system voice. `language` is used only when `id` is not a listed voice.
    func voice(for id: String, language: String = "en") -> Voice {
        Self.playable(id, language: language, englishKokoro: settings.fallbackVoiceID, in: voices)
    }

    nonisolated static func playable(_ id: String, language: String, englishKokoro: String, in voices: [Voice]) -> Voice {
        let wanted = voices.first { $0.id == id }
        if let wanted, wanted.installed { return wanted }
        let lang = wanted?.language ?? language
        let kokoro = lang == "fr" ? "ff_siwis" : englishKokoro
        if let k = voices.first(where: { $0.id == kokoro && $0.installed }) { return k }
        return voices.first { $0.engine == .system && $0.language == lang }
            ?? SystemEngine.voice(language: lang)
            ?? voices.first { $0.engine == .system }
            ?? Voice(id: "", name: "System", accent: "", gender: "", engine: .system, installed: true)
    }

    /// The Kokoro voice a read in `language` switches to if its model falls behind (V3); nil when not installed.
    private func kokoroFallback(_ language: String) -> Voice? {
        let id = language == "fr" ? "ff_siwis" : settings.fallbackVoiceID
        return voices.first { $0.id == id && $0.installed }
    }

    func refreshModelStates() {
        let rows = engines.downloadables().map { d in
            ModelRow(title: d.title, megabytes: d.modelMegabytes,
                     state: downloadStates[d.title] ?? (d.isModelInstalled ? .ready : .missing(megabytes: d.modelMegabytes)))
        }
        if rows != models { models = rows }
        guard downloadTask == nil else { return }
        voiceModel = NeuralEngine.modelInstalled() ? .ready : .missing(megabytes: Self.voiceMegabytes)
        dictationModel = Transcriber.isDownloaded ? .ready : .missing(megabytes: Self.dictationMegabytes)
    }

    /// Downloads one of `engines.downloadables()` (Qwen3, Parakeet v3, the Kokoro French pack). Only from the user's
    /// click on the Models or Voices page (PLAN 0.3.0 rev. 6), or an explicit `talkread models download --model`, which
    /// never offers Breeze (its licence is shown beside its download): nothing calls this on its own.
    func download(_ title: String) {
        guard let d = engines.downloadables().first(where: { $0.title == title }), !d.isModelInstalled else { return }
        if case .downloading = downloadStates[title] { return }
        downloadStates[title] = .downloading(progress: 0)
        refreshModelStates()
        updateActivity()
        Task { [weak self] in
            do {
                try await d.downloadModel { p in Task { @MainActor in self?.downloadProgress(title, p) } }
                self?.downloadStates[title] = nil
            } catch {
                self?.downloadStates[title] = .failed(error.localizedDescription)
                Log.write("\(title) download failed: \(error)")
            }
            guard let self else { return }
            updateActivity()
            await loadVoices()   // installed flags and rows
        }
    }

    /// Whole percents only, so a chatty downloader does not redraw every window per packet.
    private func downloadProgress(_ title: String, _ p: Double) {
        guard case .downloading(let old) = downloadStates[title], Int(p * 100) != Int(old * 100) else { return }
        downloadStates[title] = .downloading(progress: min(0.99, max(0, p)))
        refreshModelStates()
    }

    func downloadModels() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            if voiceModel != .ready {
                let id = voices.first { $0.id == self.settings.voiceID && $0.engine == .neural && $0.language == "en" }?.id ?? settings.fallbackVoiceID
                let kokoro = engines.engine(for: Voice(id: id, name: "", accent: "", gender: "", engine: .neural, installed: false))
                await download(\.voiceModel, pollDir: Self.voiceModelDir) { _ in try await kokoro.prepare(voice: id) }
            }
            if dictationModel != .ready, !Task.isCancelled {
                await download(\.dictationModel, pollDir: nil) { report in try await self.dictation.asr.load(progress: report) }
            }
            guard !Task.isCancelled else { return }   // cancelModelDownload has already reset the states
            modelsWarm = true
            downloadTask = nil
            updateActivity()                          // the idle unload starts counting now (Sol #16)
            await loadVoices()
        }
        updateActivity()
    }

    /// Stops waiting for the download; whatever finished stays, the rest shows as missing again.
    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshModelStates()
        updateActivity()
    }

    /// The transcriber reports its own progress; Kokoro's `prepare` reports none through the contract, so its progress
    /// is the bytes on disk against the expected size.
    private func download(_ state: ReferenceWritableKeyPath<AppModel, ModelState>, pollDir: URL?,
                          load: @escaping (@escaping (Double) -> Void) async throws -> Void) async {
        self[keyPath: state] = .downloading(progress: 0)
        let report: (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, case .downloading = self[keyPath: state] else { return }   // never undo .ready
                self[keyPath: state] = .downloading(progress: min(0.99, max(0, p)))
            }
        }
        let poll = Task {
            guard let pollDir else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { report(Double(Self.bytes(in: pollDir)) / Double(Self.voiceMegabytes << 20)) }
            }
        }
        do {
            try await load(report)
            poll.cancel()
            self[keyPath: state] = .ready
        } catch {
            poll.cancel()
            guard !Task.isCancelled else { return refreshModelStates() }
            self[keyPath: state] = .failed(error.localizedDescription)
            Log.write("model download failed: \(error)")
        }
    }

    nonisolated private static func bytes(in dir: URL) -> Int {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Ownership (PLAN decisions 16 and 20)

    /// The human (GUI, menu, hotkeys, voice previews) always passes.
    nonisolated static func isHuman(_ caller: String) -> Bool { caller == "user" || caller.hasPrefix("ui-") }

    /// Guards every session-mutating route: another control caller's live read means busy, unless forced.
    func checkOwner(_ caller: String, force: Bool) throws {
        guard let o = owner, o.caller != caller, !force, !Self.isHuman(caller) else { return }
        throw AppError.busy(o.caller)
    }

    /// Stops the current read and reserves the next one for `caller`. Synchronous: call it before any await.
    func reserve(_ caller: String) -> UUID {
        stopSession()
        let id = UUID()
        owner = (caller, id)
        return id
    }

    var liveSession: ReadSession? {
        guard let s = session, s.state == .preparing || s.state == .playing || s.state == .paused else { return nil }
        return s
    }

    // MARK: Reading (the GUI, menu and hotkeys are caller "user")

    func readSelection() {
        if let s = session, s.state == .playing || s.state == .preparing { stopReading(); return }
        let id = reserve("user")
        let app = NSWorkspace.shared.frontmostApplication
        Task { await captureAndRead(id: id, app: app) }
    }

    /// Captures the selection and starts the read reserved as `id`; nil when nothing was found or another read took over.
    @discardableResult func captureAndRead(id: UUID, app: NSRunningApplication?) async -> ReadSession? {
        let capture = await TextCapture.capture(app: app)
        guard owner?.sessionID == id else {
            // No Highlighter will end this read (E8); a newer read on the same app keeps its wake.
            if let capture, highlightedPID != capture.pid { AXWake.restore(capture.pid) }
            return nil
        }
        guard let capture, !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let capture { AXWake.restore(capture.pid) }
            owner = nil
            MiniPlayer.shared.flash("Select some text first")
            return nil
        }
        Log.write("read: capture via \(capture.source), \(capture.text.utf16.count) characters"
                  + (capture.hiddenRemoved > 0 ? ", hidden text cut \(capture.hiddenRemoved)" : ""))
        let s = startSession(capture.text, capture: capture, id: id)   // the player says "Reading clipboard" itself
        appendRead(capture.text, app: app?.localizedName, bundleID: app?.bundleIdentifier)
        return s
    }

    /// Read from here (1.0): the paragraph under the pointer (or the one the glyph showed) to the end of its page, with
    /// no selection. Unlike Read selection it never toggles: pressing it during a read starts again from the pointer.
    func readHere(block: PointerCapture.Block? = nil) {
        let id = reserve("user")
        let point = ReadHereGlyph.pointer()
        Task { await captureHereAndRead(id: id, point: point, block: block) }
    }

    /// Finds the paragraph at `point` (AX top-left coordinates) unless `block` is given, and starts the read reserved
    /// as `id`; nil when there is no text there or another read took over.
    @discardableResult func captureHereAndRead(id: UUID, point: CGPoint, block: PointerCapture.Block?) async -> ReadSession? {
        var found = block
        if let block {
            // Stopping the last read put its app back (E8); the glyph found this paragraph while it was awake, so wake it again.
            await AXWake.wake(AXUIElementCreateApplication(block.pid), pid: block.pid)
        } else {
            found = await PointerCapture.block(at: point, wake: true) { [weak self] in self?.highlightedPID }
        }
        let capture = found.flatMap(PointerCapture.capture)
        let pid = capture?.pid ?? found?.pid
        guard owner?.sessionID == id else {
            // No Highlighter will end this read (E8); a newer read on the same app keeps its wake.
            if let pid, highlightedPID != pid { AXWake.restore(pid) }
            return nil
        }
        guard let capture else {
            if let pid { AXWake.restore(pid) }
            owner = nil
            MiniPlayer.shared.flash("No text under the pointer")
            return nil
        }
        Log.write("read here: \(capture.text.utf16.count) characters" + (capture.selectionStart != nil ? " from native text" : " from a web area")
                  + (capture.hiddenRemoved > 0 ? ", hidden text cut \(capture.hiddenRemoved)" : ""))
        let s = startSession(capture.text, capture: capture, id: id)
        let app = NSRunningApplication(processIdentifier: capture.pid)
        appendRead(capture.text, app: app?.localizedName, bundleID: app?.bundleIdentifier)
        return s
    }

    func readScreenshot() {
        let id = reserve("user")
        let app = NSWorkspace.shared.frontmostApplication   // the app the picture is of, as for a selection
        Task {
            let text = await ScreenshotCapture.capture()
            guard owner?.sessionID == id else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                owner = nil
                MiniPlayer.shared.flash(ScreenshotCapture.lastFailure ?? "No text found in that area.")
                return
            }
            startSession(text, capture: nil, id: id, source: "screenshot")
            appendRead(text, app: app?.localizedName, bundleID: app?.bundleIdentifier)
        }
    }

    /// `voice` (additive) reads with that voice without changing the setting: the Voices pane's preview.
    func speak(_ text: String, title: String?, caller: String, voice: String? = nil, rate: Float? = nil) throws {
        try checkOwner(caller, force: false)
        startSession(text, capture: nil, id: reserve(caller), voice: voice.map { self.voice(for: $0) }, rate: rate)
    }

    /// Plays a short sample in that voice without choosing it (the Voices page), at 1x whatever the saved speed, so a
    /// Breeze voice is heard as itself rather than handed to Kokoro above its 1.5x (Sol inspection 5 #5).
    func preview(_ v: Voice) {
        let text = v.language == "fr" ? "Bonjour, je suis \(v.name). Voici comment je lis vos textes."
            : "Hello, I'm \(v.name). This is how I sound reading your text."
        try? speak(text, title: nil, caller: "ui-preview", voice: v.id, rate: 1)
        previewSession = session
    }
    /// The read `preview` started; any later read replaces `session`, so it is a preview only while it is that one.
    private weak var previewSession: ReadSession?
    /// Furniture ranges per PDF document, found once (`furniture`).
    private var furnitureCache: [UUID: [Range<Int>]] = [:]

    func read(_ item: LibraryItem, fromToken: Int?) {
        guard let text = try? documentText(item) else { MiniPlayer.shared.flash("Could not open “\(item.title)”"); return }
        let id = reserve("user")
        // At once unless a PDF's furniture still has to be found.
        if let skip = knownFurniture(item) { beginDocument(item, text: text, fromToken: fromToken, id: id, skip: skip); return }
        Task { await startDocument(item, text: text, fromToken: fromToken, id: id) }
    }

    /// Starts at `fromToken`, else at the saved position. nil when another read took over while a PDF's furniture was found.
    @discardableResult func startDocument(_ item: LibraryItem, text: String, fromToken: Int?, id: UUID) async -> ReadSession? {
        let known = knownFurniture(item)
        let skip = if let known { known } else { await furniture(item, text: text) }
        guard owner?.sessionID == id else { return nil }
        return beginDocument(item, text: text, fromToken: fromToken, id: id, skip: skip)
    }

    @discardableResult private func beginDocument(_ item: LibraryItem, text: String, fromToken: Int?, id: UUID, skip: [Range<Int>]) -> ReadSession {
        let saved = library.first { $0.id == item.id }?.position ?? item.position
        return startSession(text, capture: nil, id: id, startToken: fromToken ?? saved, source: "document", item: item.id, skip: skip)
    }

    /// The ranges a read skips when no PDF has to be opened for them: none (not a PDF, or the setting is off) or cached.
    private func knownFurniture(_ item: LibraryItem) -> [Range<Int>]? {
        guard settings.skipHeadersAndFooters, item.kind == "pdf" else { return [] }
        return furnitureCache[item.id]
    }

    /// A PDF's running headers, footers and page numbers, when Settings skips them. The pages are joined exactly as the
    /// importer joined them; a stored text that no longer matches its PDF unit for unit skips nothing. Found once per
    /// document (the reader fills it in when it opens the PDF), since extracting a long PDF's text takes a while.
    private func furniture(_ item: LibraryItem, text: String) async -> [Range<Int>] {
        let url = Paths.documents.appendingPathComponent(item.fileName)
        // Off the main actor: extracting every page of a long PDF must not freeze the UI.
        let found = await Task.detached(priority: .userInitiated) { () -> [Range<Int>] in
            guard let pdf = PDFDocument(url: url) else { return [] }
            let joined = Importer.pdfText(pdf)
            return joined.text.utf16.elementsEqual(text.utf16) ? PageFurniture.ranges(text, pageStarts: joined.pageStarts) : []
        }.value
        furnitureCache[item.id] = found
        return found
    }

    /// `joined`: the PDF's text as `Importer.pdfText` joins it; `text`: the stored document text a read speaks.
    func rememberFurniture(_ item: LibraryItem, text: String, joined: String, pageStarts: [Int]) {
        guard settings.skipHeadersAndFooters else { return }
        furnitureCache[item.id] = joined.utf16.elementsEqual(text.utf16) ? PageFurniture.ranges(text, pageStarts: pageStarts) : []
    }

    @discardableResult
    func startSession(_ text: String, capture: Capture?, id: UUID, startToken: Int = 0, voice: Voice? = nil,
                      rate: Float? = nil, source: String? = nil, item: UUID? = nil, skip: [Range<Int>] = []) -> ReadSession {
        // One language per read (PLAN 0.3.0 rev. 8): French text reads with the French voice; an explicit voice wins.
        let v = voice ?? (Language.detect(text) == "fr" ? self.voice(for: settings.frenchVoiceID, language: "fr") : self.voice(for: settings.voiceID))
        let r = rate ?? settings.speed
        let s = ReadSession(text: text, capture: capture, voice: v, rate: r, startToken: startToken, engines: engines,
                            lexicon: Self.loadJSON(Paths.pronunciations) ?? [:], fallback: v.engine.isLarge ? kokoroFallback(v.language) : nil,
                            skip: skip, skipCitations: settings.skipCitations)
        session = s
        sessionInfo = (source ?? capture.map { "\($0.source)" } ?? "provided", r, item)
        modelsWarm = true
        sessionWatch = s.$state.sink { [weak self] state in self?.sessionStateChanged(state, id: id) }
        s.start()
        if capture?.hasGeometry == true, settings.showHighlight {   // clipboard and provided text have no place on screen
            let h = Highlighter(session: s, style: Overlay.Style(settings))
            h.useOCRFallback = settings.useOCRFallback
            h.start()
            highlighter = h
        } else if let capture, capture.hasGeometry {
            AXWake.restore(capture.pid)   // highlight off: no Highlighter will end this read and restore the app (E8)
        }
        return s
    }

    /// `@Published` delivers the new state before storing it, so this reads `state`, not `session.state`.
    private func sessionStateChanged(_ state: ReadSession.State, id: UUID) {
        readState = state
        switch state {
        case .finished, .failed:
            if owner?.sessionID == id { owner = nil }
            if state == .finished, let item = sessionInfo.item { setPosition(item, 0) }   // read to the end: start over next time
            highlighter?.stop()
            highlighter = nil
        case .paused:
            rememberPosition()
        default: break
        }
        updateActivity()
    }

    /// Stops the current read, if any, and releases its ownership.
    func stopSession() {
        rememberPosition()
        sessionWatch = nil
        highlighter?.stop()
        highlighter = nil
        liveSession?.stop()
        owner = nil
        readState = nil
        updateActivity()
    }

    func togglePause() {
        guard let s = liveSession else { return }
        owner?.caller = "user"
        if s.state == .paused { s.resume() } else { s.pause() }
    }

    func stopReading() { stopSession() }

    /// The control route refuses a larger skip; every other path clamps to it (Sol #5).
    nonisolated static let maxSkip = 10_000
    /// `talkread history`: most rows per call, and the text it may carry (the socket reply is capped at 8 MB).
    nonisolated static let maxHistoryLimit = 500, maxHistoryBytes = 2_000_000

    func skip(_ sentences: Int) {
        guard let s = liveSession else { return }
        owner?.caller = "user"
        s.skip(sentences: min(max(sentences, -Self.maxSkip), Self.maxSkip))
    }

    func setSpeed(_ s: Float) {
        owner?.caller = "user"
        changeSpeed(s)
    }

    /// The speed commands' one path (the GUI, the keys and control `speed`; `settings-set` stays a plain preference
    /// write): the saved speed, applied to a live read too, except during a preview, which changes alone.
    func changeSpeed(_ s: Float) {
        var next = settings
        next.speed = s
        next = next.validated()
        // A preview plays at its own speed: a speed chosen during it (⌥D/⌥S, the menus) changes that read only, never
        // the saved speed.
        if let live = liveSession, live === previewSession {
            sessionInfo.rate = next.speed
            return live.setRate(next.speed)
        }
        settings = next
        applySpeedToLiveRead()
    }

    /// An explicit speed choice also reaches a live read playing at another rate (a 1x preview) when the saved value did
    /// not change, so settingsDidChange returned early (Sol verification 6).
    func applySpeedToLiveRead() {
        guard let live = liveSession, sessionInfo.rate != settings.speed else { return }
        sessionInfo.rate = settings.speed
        live.setRate(settings.speed)
    }

    /// The speed the mini player, the menu bar and the reader show and step from: the live read's (a preview plays at
    /// 1x), else the saved one.
    var activeSpeed: Float { liveSession == nil ? settings.speed : sessionInfo.rate }

    /// ⌥D/⌥S, ⌘+/⌘− and the speed panel's plus and minus: to the next 0.25 mark from what is playing.
    func stepSpeed(up: Bool) { setSpeed(TalkReadCore.Settings.steppedSpeed(activeSpeed, up: up)) }

    /// The picker, the menus and `talkread voice`: a French voice becomes the French voice, any other the English one;
    /// an English Kokoro voice is also the one a slower model falls back to. Applies from the next read (V1).
    func setVoice(_ id: String) {
        let v = voices.first { $0.id == id }
        var next = settings
        if v?.language == "fr" {
            next.frenchVoiceID = id
        } else {
            next.voiceID = id
            if v?.engine == .neural { next.fallbackVoiceID = id }
        }
        settings = next
    }

    /// Additive: the Dictation pane's delete. The history belongs to DictationController (WP5).
    func deleteDictation(_ id: UUID) { dictation.delete(id) }

    /// Additive: the Dictation history's "Insert again" (Sol #17). Hides Talk & Read so the app the user came from is
    /// frontmost again, then types the entry there through the guarded Inserter (secure fields refused, clipboard restored).
    func insertAgain(_ id: UUID) {
        NSApp.hide(nil)
        Task {
            do {
                guard let outcome = try await reinsertInOtherApp(id) else {
                    return MiniPlayer.shared.flash("Click where the text should go, then try again")
                }
                switch outcome.result {
                case .inserted: break
                case .refusedSecure: MiniPlayer.shared.flash(Inserter.refusal())
                case .failed(let reason): MiniPlayer.shared.flash(reason)
                }
            } catch let error as AppError {
                MiniPlayer.shared.flash(error.message)
            } catch {
                MiniPlayer.shared.flash(error.localizedDescription)
            }
        }
    }

    func checkInsertAgain() throws {
        guard !insertingAgain else { throw AppError(code: "busy", message: "Insert Again is still typing. Retry when it finishes.") }
    }

    /// Insert again's typing, shared with `talkread insert-again`: hides Talk & Read if it is in front, then types the
    /// entry into the app that is (or comes) forward. nil when no other app comes forward within a second.
    func reinsertInOtherApp(_ id: UUID) async throws -> (app: NSRunningApplication, result: InsertResult)? {
        try checkInsertAgain()
        insertingAgain = true
        defer { insertingAgain = false }
        if NSApp.isActive { NSApp.hide(nil) }
        guard let app = await insertAgainTarget() else { return nil }
        return (app, await dictation.reinsert(id, targetPID: app.processIdentifier))
    }

    /// The frontmost app once it is not Talk & Read, waiting up to `seconds`; nil if none comes forward.
    static func otherFrontmostApp(within seconds: Double) async -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { return app }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pauseForSleep() {
        if let s = liveSession, s.state != .paused { s.pause() }
    }

    // MARK: Activity token and idle unload

    /// Reading, dictating (recording, transcribing a file, typing) or downloading models. A paused read is not busy: its
    /// models unload after the idle time too, and resuming loads them again (PLAN 0.3.0 rev. 5).
    private var busy: Bool {
        readState == .preparing || readState == .playing || dictating || downloadTask != nil
            || downloadStates.values.contains { if case .downloading = $0 { true } else { false } }
    }

    /// Holds a `.userInitiatedAllowingIdleSystemSleep` activity only while busy, and unloads the speech models after
    /// `unloadAfterMinutes` idle. Every busy source calls this when it starts and ends (Sol #16).
    private func updateActivity() {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Reading aloud, dictating or downloading speech models")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        if busy {
            modelsWarm = true   // also a read resumed after an unload
            unloadTask?.cancel()
            unloadTask = nil
            return
        }
        freeUnchosenModels()
        if modelsWarm, unloadTask == nil {
            let delay = unloadDelay ?? .seconds(Double(settings.unloadAfterMinutes) * 60)
            unloadTask = Task { [weak self] in
                while true {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    // Busy without telling us, or the recogniser refused (still loading or draining, Sol #24): wait
                    // another period rather than give up.
                    guard !busy, !engines.isBusy, dictation.unloadModel() else { continue }
                    engines.unloadAll()
                    modelsWarm = false
                    unloadTask = nil
                    Log.write("speech models unloaded after \(delay) idle")
                    return
                }
            }
        }
    }

    // MARK: Library

    func importFile(_ url: URL) async throws -> LibraryItem {
        let doc = try await Task.detached { try await Importer.load(url) }.value
        let ext = url.pathExtension.lowercased()
        let id = UUID()
        let item = LibraryItem(id: id, title: doc.title, kind: doc.kind, fileName: "\(id.uuidString).\(ext.isEmpty ? "txt" : ext)",
                               added: Date(), position: 0)
        try FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: Paths.documents.appendingPathComponent(item.fileName))
        try store(doc.text, for: item)
        return add(item)
    }

    func importWebPage(_ url: URL) async throws -> LibraryItem {
        let doc = try await Task.detached { try await Importer.load(web: url) }.value
        let id = UUID()
        let item = LibraryItem(id: id, title: doc.title, kind: "web", fileName: "\(id.uuidString).txt", added: Date(), position: 0)
        try store(doc.text, for: item)
        return add(item)
    }

    func importText(_ text: String, title: String) -> LibraryItem {
        let id = UUID()
        let item = LibraryItem(id: id, title: title, kind: "pasted", fileName: "\(id.uuidString).txt", added: Date(), position: 0)
        do { try store(text, for: item) } catch { Log.write("saving pasted text failed: \(error)") }
        return add(item)
    }

    /// Every item keeps its extracted text as `<uuid>.txt` beside the copy, so reading never re-parses the original.
    func documentText(_ item: LibraryItem) throws -> String {
        try String(contentsOf: Self.textURL(item), encoding: .utf8)
    }

    func savePosition(_ item: LibraryItem, token: Int) { setPosition(item.id, token) }

    func remove(_ item: LibraryItem) {
        library.removeAll { $0.id == item.id }
        Self.saveJSON(library, to: Paths.library)
        try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(item.fileName))
        try? FileManager.default.removeItem(at: Self.textURL(item))
    }

    private func store(_ text: String, for item: LibraryItem) throws {
        try FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
        try text.write(to: Self.textURL(item), atomically: true, encoding: .utf8)
    }

    private func add(_ item: LibraryItem) -> LibraryItem {
        library.insert(item, at: 0)
        Self.saveJSON(library, to: Paths.library)
        return item
    }

    private func setPosition(_ id: UUID, _ token: Int) {
        guard let i = library.firstIndex(where: { $0.id == id }), library[i].position != token else { return }
        library[i].position = token
        Self.saveJSON(library, to: Paths.library)
    }

    private func rememberPosition() {
        if let item = sessionInfo.item, let token = liveSession?.currentToken { setPosition(item, token) }
    }

    private func appendRead(_ text: String, app: String?, bundleID: String?) {
        recentReads.insert(ReadEntry(id: UUID(), date: Date(), app: app, text: String(text.prefix(5000)), bundleID: bundleID), at: 0)
        if recentReads.count > settings.historyLimit { recentReads.removeLast(recentReads.count - settings.historyLimit) }   // as for dictations
        Self.saveJSON(recentReads, to: Paths.reads)
    }

    /// Home's "paste and listen": text typed into Talk & Read itself, kept in the history as read in Talk & Read.
    /// (Read again, the CLI's `speak` and library documents are not recorded: they would fill the history with repeats.)
    func recordOwnRead(_ text: String) { appendRead(text, app: nil, bundleID: nil) }

    /// Home's play button and `talkread read-pasted`: keeps the text in the Library as pasted text (titled by its first
    /// line unless `title` is given), reads it as the read reserved as `id`, and records it in the History.
    @discardableResult func readPasted(_ text: String, title: String? = nil, id: UUID) throws -> (item: LibraryItem, session: ReadSession) {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Pasted text"
        let item = importText(text, title: title ?? String(firstLine.prefix(60)))
        let savedText: String
        do { savedText = try documentText(item) } catch {
            if owner?.sessionID == id { owner = nil }
            throw AppError(code: "failed", message: "Could not open “\(item.title)”")
        }
        let s = beginDocument(item, text: savedText, fromToken: nil, id: id, skip: knownFurniture(item) ?? [])   // pasted text has no page furniture
        recordOwnRead(text)
        return (item, s)
    }

    /// Changes vocabulary.json or pronunciations.json in the format the Settings editors write, then has any open editor
    /// reload (the control socket's word list commands).
    func updateWordList(_ url: URL, _ change: (inout [String: String]) -> Void) throws {
        var map = WordMapEditor.load(url)
        change(&map)
        try WordMapEditor.save(map, to: url)
        wordListsRevision += 1
    }

    /// The Home history's Delete.
    func deleteRead(_ id: UUID) {
        recentReads.removeAll { $0.id == id }
        Self.saveJSON(recentReads, to: Paths.reads)
    }

    nonisolated private static func textURL(_ item: LibraryItem) -> URL {
        Paths.documents.appendingPathComponent("\(item.id.uuidString).txt")
    }

    // MARK: Permissions

    func refreshPermissions() {
        let now = Permissions.current()
        if now != permissions { permissions = now }
    }

    func request(_ p: PermissionKind) {
        PermissionRequests.request(p) { [weak self] in self?.refreshPermissions() }
    }

    // MARK: JSON files

    /// A file that exists but does not decode is kept as `<name>.bad` instead of being overwritten by the next save.
    nonisolated static func loadJSON<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            Log.write("\(url.lastPathComponent) was unreadable, kept as \(bad.lastPathComponent): \(error)")
            return nil
        }
    }

    nonisolated static func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Log.write("saving \(url.lastPathComponent) failed: \(error)")
        }
    }
}
