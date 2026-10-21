// @MainActor observable app state; the UI binds only to these members, the control handler routes through them. Owned by WP7.
import AppKit
import AVFoundation
import Combine
import FluidAudio
import Foundation
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
}

enum PermissionKind: String { case accessibility, microphone, screenRecording }

struct Permissions: Equatable {
    var accessibility = false
    var microphone = false
    var screenRecording = false
}

enum ModelState: Equatable { case missing(megabytes: Int), downloading(progress: Double), ready, failed(String) }

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

    // Additive members (not in the ESSENTIALS contract; the UI may bind to them).
    /// One line for the mini player when there is nothing to play: "Select some text first", "Reading clipboard".
    @Published private(set) var playerMessage: String?
    /// The library item the reader shows; set by the control `open` command.
    @Published var readerItem: LibraryItem?
    /// A permission or a model is missing: the menu bar dot and the "Finish setup" row.
    var needsSetup: Bool {
        !permissions.accessibility || !permissions.microphone || voiceModel != .ready || dictationModel != .ready
    }
    /// Set by AppDelegate: windows live there, not in the model.
    var showMainWindow: (() -> Void)?

    /// Replaceable so the control self-test can read with a silent engine.
    var engines = Engines()
    /// PLAN decision 16: who owns the current read. Reserved synchronously when a read is requested, held through
    /// preparing, playing and paused, released at finished, failed or stopped.
    var owner: (caller: String, sessionID: UUID)?
    /// What the status command reports about the current read.
    private(set) var sessionInfo = (voice: "", source: "", rate: Float(1), item: UUID?.none)
    private(set) var downloadTask: Task<Void, Never>?

    private var highlighter: Highlighter?
    private var sessionWatch: AnyCancellable?
    private var dictationWatch: AnyCancellable?
    private var readState: ReadSession.State?
    private var dictating = false
    private var modelsWarm = false
    private var activity: NSObjectProtocol?
    private var unloadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    nonisolated static let voiceMegabytes = 390, dictationMegabytes = 570
    /// FluidAudio keeps TTS models in its macOS TTS cache (`TtsCacheDirectory`), versioned below this folder (`ANE-v3/<rev>`).
    nonisolated private static let voiceModelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml", isDirectory: true)
    nonisolated private static let dictationModelDir = MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetUnified)

    private init() {
        settings = Settings.load()
        library = Self.loadJSON(Paths.library) ?? []
        recentReads = Self.loadJSON(Paths.reads) ?? []
        refreshModelStates()
        dictationWatch = dictation.$state.sink { [weak self] state in
            switch state {
            case .recording, .transcribing: self?.dictating = true
            default: self?.dictating = false
            }
            self?.updateActivity()
        }
    }

    // MARK: Settings

    private func settingsDidChange(from old: Settings) {
        guard settings != old else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
        guard let s = liveSession else { return }
        if settings.speed != old.speed { sessionInfo.rate = settings.speed; s.setRate(settings.speed) }
        if settings.voiceID != old.voiceID {
            let v = voice(for: settings.voiceID)
            sessionInfo.voice = v.id
            s.setVoice(v)
        }
    }

    /// Writes the settings now (skipping the 300 ms debounce); also called at quit.
    func saveSettings() {
        saveTask?.cancel()
        do { try settings.save() } catch { Log.write("settings save failed: \(error)") }
    }

    // MARK: Voices and models

    func loadVoices() async {
        voices = await engines.neural.voices() + engines.system.voices()
        refreshModelStates()
    }

    /// The requested voice when it can play now; otherwise the best system voice (no neural model yet).
    func voice(for id: String) -> Voice {
        if let v = voices.first(where: { $0.id == id }), v.engine == .system || voiceModel == .ready { return v }
        return voices.first { $0.engine == .system }
            ?? Voice(id: "", name: "System", accent: "", gender: "", engine: .system, installed: true)
    }

    func refreshModelStates() {
        guard downloadTask == nil else { return }
        voiceModel = Self.hasModel(Self.voiceModelDir) ? .ready : .missing(megabytes: Self.voiceMegabytes)
        dictationModel = Self.hasModel(Self.dictationModelDir) ? .ready : .missing(megabytes: Self.dictationMegabytes)
    }

    func downloadModels() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            if voiceModel != .ready {
                let id = voices.first { $0.id == self.settings.voiceID && $0.engine == .neural }?.id ?? "af_heart"
                await download(\.voiceModel, dir: Self.voiceModelDir, megabytes: Self.voiceMegabytes) {
                    try await self.engines.neural.prepare(voice: id)
                }
            }
            if dictationModel != .ready {
                // ponytail: the contract has no transcriber load call; transcribing one second of silence loads (and on
                // first use downloads) the shared model. Swap for a DictationController load call if WP5 adds one.
                await download(\.dictationModel, dir: Self.dictationModelDir, megabytes: Self.dictationMegabytes) {
                    _ = try await self.dictation.transcribe(file: try Self.silentClip(), caller: "user")
                }
            }
            modelsWarm = true
            downloadTask = nil
            await loadVoices()
        }
    }

    /// Progress is bytes on disk against the expected size: FluidAudio's loaders report none through our contracts.
    private func download(_ state: ReferenceWritableKeyPath<AppModel, ModelState>, dir: URL, megabytes: Int,
                          load: @escaping () async throws -> Void) async {
        self[keyPath: state] = .downloading(progress: 0)
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self[keyPath: state] = .downloading(progress: min(0.99, Double(Self.bytes(in: dir)) / Double(megabytes << 20)))
            }
        }
        do {
            try await load()
            poll.cancel()
            self[keyPath: state] = .ready
        } catch {
            poll.cancel()
            self[keyPath: state] = .failed(error.localizedDescription)
            Log.write("model download failed: \(error)")
        }
    }

    /// Any compiled CoreML model anywhere below `dir` (FluidAudio nests some per version).
    nonisolated private static func hasModel(_ dir: URL) -> Bool {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL { if url.pathExtension == "mlmodelc" { return true } }
        return false
    }

    nonisolated private static func bytes(in dir: URL) -> Int {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// One second of 16 kHz silence in the temporary folder.
    nonisolated private static func silentClip() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talkread-warmup.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].update(repeating: 0, count: 16_000)
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
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
        guard owner?.sessionID == id else { return nil }
        guard let capture, !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            owner = nil
            playerMessage = "Select some text first"
            return nil
        }
        let s = startSession(capture.text, capture: capture, id: id)
        if capture.source == .clipboard { playerMessage = "Reading clipboard" }
        appendRead(capture.text, app: app?.localizedName)
        return s
    }

    func readScreenshot() {
        let id = reserve("user")
        Task {
            let text = await ScreenshotCapture.capture()
            guard owner?.sessionID == id else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                owner = nil
                playerMessage = "No text found in that area"
                return
            }
            startSession(text, capture: nil, id: id, source: "screenshot")
            appendRead(text, app: nil)
        }
    }

    func speak(_ text: String, title: String?, caller: String) throws {
        try checkOwner(caller, force: false)
        startSession(text, capture: nil, id: reserve(caller))
    }

    func read(_ item: LibraryItem, fromToken: Int?) {
        guard let text = try? documentText(item) else { playerMessage = "Could not open “\(item.title)”"; return }
        startDocument(item, text: text, fromToken: fromToken, id: reserve("user"))
    }

    /// Starts at `fromToken`, else at the saved position.
    @discardableResult func startDocument(_ item: LibraryItem, text: String, fromToken: Int?, id: UUID) -> ReadSession {
        let saved = library.first { $0.id == item.id }?.position ?? item.position
        return startSession(text, capture: nil, id: id, startToken: fromToken ?? saved, source: "document", item: item.id)
    }

    @discardableResult
    func startSession(_ text: String, capture: Capture?, id: UUID, startToken: Int = 0, voice: Voice? = nil,
                      rate: Float? = nil, source: String? = nil, item: UUID? = nil) -> ReadSession {
        let v = voice ?? self.voice(for: settings.voiceID)
        let r = rate ?? settings.speed
        let s = ReadSession(text: text, capture: capture, voice: v, rate: r, startToken: startToken, engines: engines,
                            lexicon: Self.loadJSON(Paths.pronunciations) ?? [:])
        playerMessage = nil
        session = s
        sessionInfo = (v.id, source ?? capture.map { "\($0.source)" } ?? "provided", r, item)
        modelsWarm = true
        sessionWatch = s.$state.sink { [weak self] state in self?.sessionStateChanged(state, id: id) }
        s.start()
        if let source = capture?.source, [.accessibility, .copied, .cursor, .ocr].contains(source) {
            highlighter = Highlighter(session: s, style: Overlay.Style())
            highlighter?.start()
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

    func skip(_ sentences: Int) {
        guard let s = liveSession else { return }
        owner?.caller = "user"
        s.skip(sentences: sentences)
    }

    func setSpeed(_ s: Float) {
        owner?.caller = "user"
        var next = settings
        next.speed = s
        settings = next.validated()
    }

    func setVoice(_ id: String) {
        owner?.caller = "user"
        settings.voiceID = id
    }

    func pauseForSleep() {
        if let s = liveSession, s.state != .paused { s.pause() }
    }

    // MARK: Activity token and idle unload

    /// Holds a `.userInitiatedAllowingIdleSystemSleep` activity only while reading or dictating, and unloads the
    /// speech models after `unloadAfterMinutes` with nothing reading, paused or dictating.
    private func updateActivity() {
        let busy = readState == .preparing || readState == .playing || dictating
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Reading aloud or dictating")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        if dictating { modelsWarm = true }
        let idle = !busy && readState != .paused
        if !idle {
            unloadTask?.cancel()
            unloadTask = nil
        } else if modelsWarm, unloadTask == nil {
            let minutes = settings.unloadAfterMinutes
            unloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self else { return }
                engines.neural.unload()
                engines.system.unload()
                // ponytail: the transcriber has no unload in the contract; WP5's controller releases it (see WP7 report).
                modelsWarm = false
                unloadTask = nil
                Log.write("speech models unloaded after \(minutes) idle minutes")
            }
        }
    }

    // MARK: Library

    func importFile(_ url: URL) async throws -> LibraryItem {
        let doc = try await Task.detached { try await Importer.load(url) }.value
        let ext = url.pathExtension.lowercased()
        let id = UUID()
        let item = LibraryItem(id: id, title: url.deletingPathExtension().lastPathComponent, kind: Self.kind(ext),
                               fileName: "\(id.uuidString).\(ext.isEmpty ? "txt" : ext)", added: Date(), position: 0)
        try FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: Paths.documents.appendingPathComponent(item.fileName))
        try store(doc.text, for: item)
        return add(item)
    }

    func importWebPage(_ url: URL) async throws -> LibraryItem {
        let doc = try await Task.detached { try await Importer.load(web: url) }.value
        let id = UUID()
        let item = LibraryItem(id: id, title: url.host() ?? url.absoluteString, kind: "web", fileName: "\(id.uuidString).txt",
                               added: Date(), position: 0)
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

    private func appendRead(_ text: String, app: String?) {
        recentReads.insert(ReadEntry(id: UUID(), date: Date(), app: app, text: String(text.prefix(5000))), at: 0)
        if recentReads.count > 100 { recentReads.removeLast(recentReads.count - 100) }
        Self.saveJSON(recentReads, to: Paths.reads)
    }

    nonisolated private static func textURL(_ item: LibraryItem) -> URL {
        Paths.documents.appendingPathComponent("\(item.id.uuidString).txt")
    }

    nonisolated private static func kind(_ ext: String) -> String {
        switch ext {
        case "pdf", "rtf", "docx", "epub": return ext
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        default: return "text"
        }
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
