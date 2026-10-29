// Control-socket command handlers. Admission (PLAN decision 20): `handle` runs concurrently, but every check and
// reservation (read owner, dictation owner, transcription slot) happens synchronously on the main actor before the
// first await, so two callers can never both pass; long work (first audio, transcripts) is awaited afterwards.
import AppKit
import Foundation
import TalkReadCore

/// A refusal with its response code; `busy` carries the owner.
struct AppError: Error {
    let code: String
    let message: String
    var data: [String: JSONValue]?

    static func busy(_ owner: String) -> AppError {
        AppError(code: "busy", message: "Busy: \(owner) is using it. Retry later, or pass --force.", data: ["owner": .string(owner)])
    }
    static func badArgs(_ message: String) -> AppError { AppError(code: "bad_args", message: message) }
}

extension AppModel {
    func handle(_ r: ControlRequest) async -> ControlResponse {
        do {
            return ControlResponse(ok: true, data: try await route(r))
        } catch let e as AppError {
            return ControlResponse(ok: false, code: e.code, message: e.message, data: e.data)
        } catch let e as ControlError {
            return ControlResponse(ok: false, code: e.code, message: e.message)
        } catch DictationError.busy(let owner) {
            let e = AppError.busy(owner)
            return ControlResponse(ok: false, code: e.code, message: e.message, data: e.data)
        } catch {
            return ControlResponse(ok: false, code: "failed", message: error.localizedDescription)
        }
    }

    private func route(_ r: ControlRequest) async throws -> [String: JSONValue] {
        let a = r.args
        switch r.command {
        case "status":
            return status()

        case "voices":
            // `current` (the English voice) is kept for 0.2 callers.
            return ["voices": .array(voices.map(Self.json)), "current": .string(settings.voiceID),
                    "english": .string(settings.voiceID), "french": .string(settings.frenchVoiceID)]

        case "speak":
            guard let text = a["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.badArgs("speak needs some text.")
            }
            let v = try a["voice"].map { voice(for: try validVoice($0)) }
            let rate = try a["speed"].map(validSpeed)
            try checkOwner(r.caller, force: r.force)
            return try await firstAudio(startSession(text, capture: nil, id: reserve(r.caller), voice: v, rate: rate))

        case "read-selection":
            try checkOwner(r.caller, force: r.force)
            let id = reserve(r.caller)
            guard let s = await captureAndRead(id: id, app: NSWorkspace.shared.frontmostApplication) else {
                throw AppError(code: "no_selection", message: "Select some text first (or another read started first).")
            }
            return try await firstAudio(s)

        case "read-here":
            let point: CGPoint
            switch (a["x"].flatMap(Double.init), a["y"].flatMap(Double.init)) {
            case (let x?, let y?) where x.isFinite && y.isFinite: point = CGPoint(x: x, y: y)
            case (nil, nil) where a["x"] == nil && a["y"] == nil: point = ReadHereGlyph.pointer()
            default: throw AppError.badArgs("read-here takes both x and y as numbers, or neither (the pointer).")
            }
            try checkOwner(r.caller, force: r.force)
            let id = reserve(r.caller)
            guard let s = await captureHereAndRead(id: id, point: point, block: nil) else {
                throw AppError(code: "no_text", message: "No text under the pointer (or another read started first).")
            }
            return try await firstAudio(s)

        case "read-file":
            let url = try fileArg(a)
            try checkOwner(r.caller, force: r.force)
            let id = reserve(r.caller)
            let doc: ImportedDocument
            do { doc = try await Task.detached { try await Importer.load(url) }.value } catch {
                if owner?.sessionID == id { owner = nil }
                throw AppError(code: "failed", message: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard owner?.sessionID == id else { throw AppError(code: "superseded", message: "Another read started first.") }
            let skip = settings.skipHeadersAndFooters ? doc.pageStarts.map { PageFurniture.ranges(doc.text, pageStarts: $0) } ?? [] : []
            return try await firstAudio(startSession(doc.text, capture: nil, id: id, source: "file", skip: skip))

        case "pause", "resume", "stop":
            try claim(r)
            if r.command == "stop" {
                stopSession()
                return ["state": .string("stopped")]
            }
            guard let s = liveSession else { throw AppError(code: "not_reading", message: "Nothing is being read.") }
            if r.command == "pause" { s.pause() } else { s.resume() }
            return ["state": .string(r.command == "pause" ? "paused" : "playing")]

        case "skip":
            guard let n = Int(a["sentences"] ?? "1"), (-AppModel.maxSkip...AppModel.maxSkip).contains(n) else {
                throw AppError.badArgs("sentences must be a whole number from -\(AppModel.maxSkip) to \(AppModel.maxSkip).")
            }
            try claim(r)
            guard let s = liveSession else { throw AppError(code: "not_reading", message: "Nothing is being read.") }
            s.skip(sentences: n)
            return ["sentences": .number(Double(n))]

        case "speed":
            guard let raw = a["value"] else { throw AppError.badArgs("speed needs a value from 0.5 to 4.0.") }
            let v = try validSpeed(raw)
            try claim(r)
            changeSpeed(v)   // as the GUI's: during a preview only the preview changes (Sol verification 7 #3)
            return ["speed": .number(Double(activeSpeed))]

        case "voice":
            guard let raw = a["id"] else { throw AppError.badArgs("voice needs an id; see `talkread voices`.") }
            let id = try validVoice(raw)
            try claim(r)
            setVoice(id)
            let v = voice(for: id)
            return ["voice": .string(id), "language": .string(v.language), "speaking": .string(v.id)]

        case "mic":
            let inputs = Microphone.inputs()
            if let choice = a["uid"] {
                guard choice == "default" || inputs.contains(where: { $0.uid == choice }) else {
                    throw AppError.badArgs("Unknown microphone '\(choice)'; see `talkread mic`.")
                }
                settings.dictationMicrophone = choice == "default" ? nil : choice   // applies from the next recording
            }
            let chosen = settings.dictationMicrophone
            return microphoneJSON().merging(["inputs": .array(inputs.map { d in
                .object(["uid": .string(d.uid), "name": .string(d.name), "default": .bool(d.isDefault), "chosen": .bool(d.uid == chosen)])
            })]) { $1 }

        case "dictate-start":
            try checkInsertAgain()
            try dictation.start(caller: r.caller, force: r.force)
            return ["state": .string(Self.name(dictation.state))]

        case "dictate-stop":
            try dictation.stop(insert: a["insert"] != "0", caller: r.caller, force: r.force)
            guard let text = await dictation.result() else {
                throw AppError(code: "failed", message: "The dictation was cancelled or could not be transcribed.")
            }
            return ["text": .string(text)]

        case "dictate-cancel":
            // As Esc and the pill's ✕: the recording stops and nothing is typed or kept.
            try dictation.cancel(caller: r.caller, force: r.force)
            return ["state": .string(Self.name(dictation.state))]

        case "insert-again":
            try checkInsertAgain()
            // The Dictation page's Insert Again (and Paste last transcript, without an id).
            let entry: DictationEntry
            if let raw = a["id"] {
                let id = try uuidArg(raw)
                guard let e = dictation.history.first(where: { $0.id == id }) else {
                    throw AppError(code: "not_found", message: "No dictation \(raw); see `talkread history --kind dictated`.")
                }
                entry = e
            } else {
                guard let e = dictation.history.first else { throw AppError(code: "empty", message: "Nothing has been dictated yet.") }
                entry = e
            }
            if let o = dictation.owner, o != r.caller, !r.force, !Self.isHuman(r.caller) { throw AppError.busy(o) }
            guard let outcome = try await reinsertInOtherApp(entry.id) else {
                throw AppError(code: "no_target", message: "No other app came forward. Click where the text should go, then retry.")
            }
            switch outcome.result {
            case .inserted(let confirmed):
                return ["id": .string(entry.id.uuidString), "app": outcome.app.localizedName.map { .string($0) } ?? .null,
                        "confirmed": .bool(confirmed)]
            case .refusedSecure: throw AppError(code: "secure_field", message: Inserter.refusal())
            case .failed(let reason): throw AppError(code: "failed", message: reason)
            }

        case "dictation-last":
            guard let e = dictation.history.first else { throw AppError(code: "empty", message: "Nothing has been dictated yet.") }
            return ["text": .string(e.text), "date": .string(ISO8601DateFormatter().string(from: e.date))]

        case "history":
            // Read-only: reads and dictations merged, newest first, as Home shows them.
            let kinds: [String: HistoryKind?] = ["all": nil, "read": .read, "dictated": .dictated]
            guard let kind = kinds[a["kind"] ?? "all"] else { throw AppError.badArgs("kind must be all, read or dictated.") }
            guard let limit = Int(a["limit"] ?? "50"), (1...Self.maxHistoryLimit).contains(limit) else {
                throw AppError.badArgs("limit must be a whole number from 1 to \(Self.maxHistoryLimit).")
            }
            let all = History.filter(History.merge(recentReads.map(\.historyItem) + dictation.history.map(\.historyItem)),
                                     kind: kind, search: a["search"] ?? "")
            let iso = ISO8601DateFormatter()
            // The socket reply is capped at 8 MB of encoded JSON, so budget what the encoder produces (escapes included),
            // not the raw text. 2 MB, well inside the limit: the control client re-scans what it has read on every receive, so a reply of several MB can outlast the server's 5 s write deadline. A cut list says so with `truncated`.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = 0
            var entries: [JSONValue] = []
            for item in all.prefix(limit) {
                let entry = JSONValue.object(["id": .string(item.uuid.uuidString), "kind": .string(item.kind.rawValue),
                                              "date": .string(iso.string(from: item.date)),
                                              "app": item.app.map { .string($0) } ?? .null, "bundleID": item.bundleID.map { .string($0) } ?? .null,
                                              "text": .string(item.text)])
                bytes += ((try? encoder.encode(entry))?.count ?? Self.maxHistoryBytes) + 1   // +1 for the comma
                if bytes > Self.maxHistoryBytes { break }
                entries.append(entry)
            }
            return ["entries": .array(entries), "count": .number(Double(entries.count)), "matching": .number(Double(all.count)),
                    "truncated": .bool(entries.count < min(limit, all.count))]

        case "history-delete":
            // The History row's Delete. Ids are unique within a kind; --kind settles the (unlikely) clash.
            let id = try uuidArg(a["id"])
            try confirmed(a, "this History entry")
            let isRead = recentReads.contains { $0.id == id }, isDictated = dictation.history.contains { $0.id == id }
            let notFound = AppError(code: "not_found", message: "No History entry \(id.uuidString); see `talkread history`.")
            let kind: HistoryKind
            switch a["kind"] {
            case "read"?: guard isRead else { throw notFound }; kind = .read
            case "dictated"?: guard isDictated else { throw notFound }; kind = .dictated
            case nil:
                if isRead && isDictated { throw AppError.badArgs("Both a read and a dictation have this id; pass --kind read or --kind dictated.") }
                guard isRead || isDictated else { throw notFound }
                kind = isRead ? .read : .dictated
            default: throw AppError.badArgs("kind must be read or dictated.")
            }
            if kind == .read { deleteRead(id) } else { deleteDictation(id) }
            return ["deleted": .string(id.uuidString), "kind": .string(kind.rawValue)]

        case "read-again":
            // The History row's Read again (and the menu's Replay last, without an id).
            let entry: ReadEntry
            if let raw = a["id"] {
                let id = try uuidArg(raw)
                guard let e = recentReads.first(where: { $0.id == id }) else {
                    throw AppError(code: "not_found", message: "No read \(raw) in the History; see `talkread history --kind read`.")
                }
                entry = e
            } else {
                guard let e = recentReads.first else { throw AppError(code: "empty", message: "Nothing has been read yet.") }
                entry = e
            }
            try checkOwner(r.caller, force: r.force)
            return try await firstAudio(startSession(entry.text, capture: nil, id: reserve(r.caller)))

        case "dictate-file":
            let url = try fileArg(a)
            let start = Date()
            let text = try await dictation.transcribe(file: url, caller: r.caller)
            return ["text": .string(text), "ms": .number((Date().timeIntervalSince(start) * 1000).rounded())]

        case "open":
            let url = try fileArg(a)
            return try await openImported(r, name: url.lastPathComponent) { try await self.importFile(url) }

        case "open-url":
            // The Library's Open web page…: fetched once, only its text is kept.
            guard let raw = a["url"], let url = WebPageSheet.address(raw) else {
                throw AppError.badArgs("url must be a web address, for example https://example.com/article.")
            }
            return try await openImported(r, name: url.absoluteString) { try await self.importWebPage(url) }

        case "read-pasted":
            // Home's paste and listen: kept in the Library and the History, unlike `speak`.
            guard let text = a["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.badArgs("read-pasted needs some text.")
            }
            let title = a["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, title.isEmpty || title.count > 200 { throw AppError.badArgs("title must be 1 to 200 characters.") }
            try checkOwner(r.caller, force: r.force)
            let (item, s) = try readPasted(text, title: title, id: reserve(r.caller))
            WindowRouter.shared.open(item)
            if a["show"] == "1" { WindowRouter.shared.showMainWindow() }
            var data: [String: JSONValue] = ["id": .string(item.id.uuidString), "title": .string(item.title)]
            data.merge(try await firstAudio(s)) { $1 }
            return data

        case "library":
            let iso = ISO8601DateFormatter()
            let reading = liveSession == nil ? nil : sessionInfo.item
            return ["items": .array(library.map { item in
                .object(["id": .string(item.id.uuidString), "title": .string(item.title), "kind": .string(item.kind),
                         "added": .string(iso.string(from: item.added)), "position": .number(Double(item.position)),
                         "reading": .bool(item.id == reading)])
            }), "count": .number(Double(library.count))]

        case "library-open":
            // A Library card: shows it in the reader; with read 1, Read (saved position) or Read from the start.
            var item = try libraryItem(a["id"])
            let andRead = a["read"] == "1"
            if a["from"] != nil && !andRead { throw AppError.badArgs("from goes with --read 1.") }
            let text: String
            do { text = try documentText(item) } catch {
                throw AppError(code: "failed", message: "Could not open “\(item.title)”: \(error.localizedDescription)")
            }
            let words = await documentWordCount(text)   // a book takes a moment: off the main actor
            item = try libraryItem(a["id"])
            let start: Int?                                      // nil: the saved position
            switch a["from"] ?? "saved" {
            case "saved": start = nil
            case "start": start = 0
            case let raw:
                guard let n = Int(raw), (0..<max(words, 1)).contains(n) else {
                    throw AppError.badArgs("from must be saved, start or a word number from 0 to \(max(words - 1, 0)).")
                }
                start = n
            }
            try checkOwner(r.caller, force: r.force)
            WindowRouter.shared.open(item)                       // the reader shows it; no window comes forward
            if a["show"] == "1" { WindowRouter.shared.showMainWindow() }
            var data: [String: JSONValue] = ["id": .string(item.id.uuidString), "title": .string(item.title), "kind": .string(item.kind),
                                             "position": .number(Double(item.position)), "words": .number(Double(words))]
            if andRead {
                guard let s = await startDocument(item, text: text, fromToken: start, id: reserve(r.caller)) else {
                    throw AppError(code: "superseded", message: "Another read started first.")
                }
                data.merge(try await firstAudio(s)) { $1 }
            }
            return data

        case "library-remove":
            // A Library card's Remove from Library: the item, its copy of the file and its text.
            let item = try libraryItem(a["id"])
            try confirmed(a, "“\(item.title)” from the Library, with its saved copy and text")
            if liveSession != nil, sessionInfo.item == item.id { try checkOwner(r.caller, force: r.force) }   // never under another caller's read
            WindowRouter.shared.libraryPath.removeAll { $0.id == item.id }   // the reader would show a missing file
            remove(item)
            return ["removed": .string(item.id.uuidString), "title": .string(item.title)]

        case "settings-get":
            let all = settings.json()
            guard let key = a["key"] else { return all }
            guard Settings.keys.contains(key) else { throw AppError.badArgs("Unknown setting '\(key)'. Keys: \(Settings.keys.joined(separator: ", ")).") }
            return [key: all[key] ?? .null]

        case "settings-set":
            guard let key = a["key"], let raw = a["value"] else { throw AppError.badArgs("settings-set needs a key and a value.") }
            var next = settings
            do { try next.set(key, to: raw) } catch let e as ControlError { throw AppError.badArgs(e.message) }
            switch key {
            case "voiceID": _ = try validVoice(next.voiceID, language: "en")
            case "frenchVoiceID": _ = try validVoice(next.frenchVoiceID, language: "fr")
            case "fallbackVoiceID": _ = try validVoice(next.fallbackVoiceID, language: "en", engine: .neural)
            default: break
            }
            if ["speed", "voiceID", "frenchVoiceID", "fallbackVoiceID"].contains(key) { try claim(r) }
            settings = next
            return [key: settings.json()[key] ?? .null]

        case "shortcuts-reset":
            // Settings ▸ Shortcuts ▸ Reset: every shortcut and the hold key back to the defaults.
            try confirmed(a, "your own shortcuts")
            var next = settings
            next.resetShortcuts()
            settings = next
            let all = settings.json()
            return Dictionary(uniqueKeysWithValues: (Settings.chords.map(\.key) + ["dictationHoldKey"]).map { ($0, all[$0] ?? .null) })

        case "vocabulary":
            return ["entries": Self.wordListJSON(WordMapEditor.load(Paths.vocabulary), key: "heard", value: "typed"),
                    "suggestions": .array(dictation.suggestions.map { .object(["heard": .string($0.heard), "typed": .string($0.typed)]) }),
                    "learnCorrections": .bool(settings.learnCorrections)]

        case "pronunciations":
            return ["entries": Self.wordListJSON(WordMapEditor.load(Paths.pronunciations), key: "word", value: "say")]

        case "vocabulary-set", "pronunciation-set":
            let vocabulary = r.command == "vocabulary-set"
            let (keyName, valueName) = vocabulary ? ("heard", "typed") : ("word", "say")
            let key = try wordArg(a[keyName], keyName), value = try wordArg(a[valueName], valueName)
            do {
                try updateWordList(vocabulary ? Paths.vocabulary : Paths.pronunciations) { map in
                    // One row per word: an existing row that differs only in case is replaced.
                    for old in map.keys where old.caseInsensitiveCompare(key) == .orderedSame { map[old] = nil }
                    map[key] = value
                }
            } catch { throw AppError(code: "failed", message: "Could not save: \(error.localizedDescription)") }
            return [keyName: .string(key), valueName: .string(value)]

        case "vocabulary-remove", "pronunciation-remove":
            let vocabulary = r.command == "vocabulary-remove"
            let keyName = vocabulary ? "heard" : "word"
            let key = try wordArg(a[keyName], keyName)
            try confirmed(a, "“\(key)” from \(vocabulary ? "the vocabulary" : "the pronunciations")")
            let url = vocabulary ? Paths.vocabulary : Paths.pronunciations
            let matches = WordMapEditor.load(url).keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }
            guard !matches.isEmpty else {
                throw AppError(code: "not_found", message: "“\(key)” is not in \(vocabulary ? "the vocabulary; see `talkread vocabulary`" : "the pronunciations; see `talkread pronunciations`").")
            }
            do { try updateWordList(url) { map in for old in matches { map[old] = nil } } } catch {
                throw AppError(code: "failed", message: "Could not save: \(error.localizedDescription)")
            }
            return ["removed": .array(matches.sorted().map { .string($0) })]

        case "vocabulary-suggestion":
            // A suggestion from your corrections: Add (to the vocabulary) or Dismiss.
            guard let heard = a["heard"], let typed = a["typed"] else { throw AppError.badArgs("vocabulary-suggestion needs heard and typed.") }
            guard let c = dictation.suggestions.first(where: { $0.heard == heard && $0.typed == typed }) else {
                throw AppError(code: "not_found", message: "No suggestion \(heard) → \(typed); see `talkread vocabulary`.")
            }
            switch a["action"] {
            case "accept": try dictation.acceptSuggestion(c)
            case "dismiss": dictation.dismissSuggestion(c)
            default: throw AppError.badArgs("action must be accept or dismiss.")
            }
            return ["action": .string(a["action"] ?? ""), "heard": .string(heard), "typed": .string(typed)]

        case "models":
            switch a["action"] ?? "status" {
            case "status":
                if a["model"] != nil { throw AppError.badArgs("model goes with download.") }
            case "download":
                if let name = a["model"] {
                    try downloadOptional(name)               // returns at once; `models` shows the progress
                } else {
                    downloadModels()
                    await downloadTask?.value
                }
            default: throw AppError.badArgs("models takes status or download.")
            }
            return modelsJSON()

        case "update-check":
            // Sparkle's own window shows the outcome and asks before installing; `status` reports it under updates.
            let r = try Updates.shared.check()
            return ["started": .bool(r.started), "checkID": r.checkID.map { .string($0) } ?? .null]

        default:
            throw AppError(code: "unknown_command", message: "Unknown command '\(r.command)'.")
        }
    }

    /// Admission for routes that change the current read: busy unless the caller owns it, forces or is the human;
    /// then the caller owns it.
    private func claim(_ r: ControlRequest) throws {
        try checkOwner(r.caller, force: r.force)
        owner?.caller = r.caller
    }

    /// `open` and `open-url`: imports, shows the item in the reader (no focus change unless show is 1) and, with read 1,
    /// reads it. The read is reserved before the import, so another caller cannot start one in between.
    func openImported(_ r: ControlRequest, name: String, _ load: () async throws -> LibraryItem) async throws -> [String: JSONValue] {
        let a = r.args
        var id: UUID?
        try checkOwner(r.caller, force: r.force)
        if a["read"] == "1" {
            id = reserve(r.caller)
        }
        let item: LibraryItem
        do { item = try await load() } catch {
            if let id, owner?.sessionID == id { owner = nil }
            throw AppError(code: "failed", message: "Could not open \(name): \(error.localizedDescription)")
        }
        let current: LibraryItem
        do { current = try libraryItem(item.id.uuidString) } catch {
            if let id, owner?.sessionID == id { owner = nil }
            throw error
        }
        var data: [String: JSONValue] = ["id": .string(item.id.uuidString), "title": .string(item.title), "kind": .string(item.kind)]
        if (id != nil && owner?.sessionID != id) || (owner != nil && owner?.caller != r.caller && !r.force && !Self.isHuman(r.caller)) {   // as checkOwner
            let notice = owner.map { "Imported; not shown because \($0.caller) is reading." }
                ?? "Imported; not shown because the read reservation ended."
            if let id, owner?.sessionID == id { owner = nil }
            data["shown"] = .bool(false)
            data["notice"] = .string(notice)
            return data
        }
        WindowRouter.shared.open(current)                    // the reader shows it; no window comes forward
        if a["show"] == "1" { WindowRouter.shared.showMainWindow() }
        data["shown"] = .bool(true)
        if let id {
            guard let s = await startDocument(current, text: try documentText(current), fromToken: nil, id: id) else {
                throw AppError(code: "superseded", message: "Another read started first.")
            }
            data.merge(try await firstAudio(s)) { $1 }
        }
        return data
    }

    /// `models download --model`: one optional download, as its Download button starts it. Breeze is refused: its licence
    /// is shown beside its button, and the person must see it before anything downloads.
    private func downloadOptional(_ name: String) throws {
        if name == "breeze" {
            throw AppError(code: "consent_required", message: "The Breeze voices download only from Settings ▸ Models in Talk & Read, beside their licence (personal, non-commercial use only).")
        }
        let match: [String: String] = ["qwen": "qwen", "word-timing": "parakeet", "french": "french"]
        guard let needle = match[name] else { throw AppError.badArgs("model must be qwen, word-timing or french.") }
        guard let row = models.first(where: { $0.title.lowercased().contains(needle) && !$0.title.lowercased().contains("breeze") }) else {
            throw AppError(code: "unavailable", message: "This copy of Talk & Read offers no \(name) download.")
        }
        download(row.title)                                  // nothing happens if it is installed or already downloading
    }

    /// Waits up to 5 s for the first audio of a read the caller just started.
    private func firstAudio(_ s: ReadSession) async throws -> [String: JSONValue] {
        for _ in 0..<500 {
            if let ms = s.firstAudioMs { return ["firstAudioMs": .number(Double(ms)), "voice": .string(s.effectiveVoice.id)] }
            if case .failed(let m) = s.state { throw AppError(code: "failed", message: m) }
            if s.state == .finished { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ["firstAudioMs": .null, "state": .string(Self.name(s.state)), "voice": .string(s.effectiveVoice.id)]
    }

    func status() -> [String: JSONValue] {
        let s = session
        func num(_ v: Int?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
        let reading: [String: JSONValue] = [
            "state": .string(s.map { Self.name($0.state) } ?? "idle"),
            "caller": owner.map { .string($0.caller) } ?? .null,
            "token": num(s?.currentToken),
            "sentence": num(s?.currentSentence),
            "voice": .string(s?.effectiveVoice.id ?? settings.voiceID),   // the voice speaking, after any fallback (V3)
            "fallbackReason": s?.fallbackReason.map { .string($0) } ?? .null,
            "speed": .number(Double(s == nil ? settings.speed : sessionInfo.rate)),
            "firstAudioMs": num(s?.firstAudioMs),
            "source": s == nil ? .null : .string(sessionInfo.source),
            "item": s == nil ? .null : sessionInfo.item.map { .string($0.uuidString) } ?? .null   // the Library item being read
        ]
        return [
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "reading": .object(reading),
            "dictation": .object(["state": .string(Self.name(dictation.state)), "owner": dictation.owner.map { .string($0) } ?? .null,
                                  "microphone": .object(microphoneJSON())]),
            "permissions": .object(["accessibility": .bool(permissions.accessibility), "microphone": .bool(permissions.microphone),
                                    "screenRecording": .bool(permissions.screenRecording)]),
            "models": .object(modelsJSON()),
            "updates": .object(Updates.shared.json())
        ]
    }

    /// The saved microphone ("default" or a UID), the device the next recording will use, and why it differs, if it does.
    private func microphoneJSON() -> [String: JSONValue] {
        let inputs = Microphone.inputs(), saved = settings.dictationMicrophone
        let r = Microphone.resolve(saved, in: inputs)
        let using = r.device ?? inputs.first(where: \.isDefault)
        return ["choice": .string(saved ?? "default"), "using": using.map { .string($0.name) } ?? .null,
                "notice": r.notice.map { .string($0) } ?? .null]
    }

    /// Kokoro's English voice and the dictation model, then every optional download (Qwen3, word timing, French).
    private func modelsJSON() -> [String: JSONValue] {
        let downloads = models.map { row -> JSONValue in
            guard case .object(var o) = Self.json(row.state) else { return .null }
            o["title"] = .string(row.title)
            o["megabytes"] = .number(Double(row.megabytes))
            return .object(o)
        }
        return ["voice": Self.json(voiceModel), "dictation": Self.json(dictationModel), "downloads": .array(downloads)]
    }

    // MARK: Argument checks

    private func fileArg(_ a: [String: String]) throws -> URL {
        guard let p = a["path"], !p.isEmpty else { throw AppError.badArgs("A file path is required.") }
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AppError.badArgs("No readable file at \(url.path).") }
        return url
    }

    private func uuidArg(_ raw: String?) throws -> UUID {
        guard let raw, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw AppError.badArgs("id must be an id as `talkread library` or `talkread history` lists it.")
        }
        return id
    }

    private func libraryItem(_ raw: String?) throws -> LibraryItem {
        let id = try uuidArg(raw)
        guard let item = library.first(where: { $0.id == id }) else {
            throw AppError(code: "not_found", message: "No Library item \(id.uuidString); see `talkread library`.")
        }
        return item
    }

    /// Destructive commands need `yes` (the CLI's --yes); the CLI refuses first, this guards other socket clients.
    private func confirmed(_ a: [String: String], _ what: String) throws {
        guard a["yes"] == "1" else { throw AppError(code: "needs_confirmation", message: "This removes \(what) for good. Pass --yes to confirm.") }
    }

    /// One side of a vocabulary or pronunciation row: trimmed, 1 to 200 characters, one line.
    private func wordArg(_ raw: String?, _ name: String) throws -> String {
        let v = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !v.isEmpty, v.count <= 200, !v.contains(where: \.isNewline) else { throw AppError.badArgs("\(name) must be 1 to 200 characters on one line.") }
        return v
    }

    /// A listed voice; for the voice settings also of the right language (and Kokoro, for the fallback).
    private func validVoice(_ id: String, language: String? = nil, engine: EngineKind? = nil) throws -> String {
        guard let v = voices.first(where: { $0.id == id }) else { throw AppError.badArgs("Unknown voice '\(id)'; see `talkread voices`.") }
        if let language, v.language != language {
            throw AppError.badArgs("'\(id)' is not \(language == "fr" ? "a French" : "an English") voice; see `talkread voices`.")
        }
        if let engine, v.engine != engine { throw AppError.badArgs("'\(id)' is not a \(engine.modelName) voice; see `talkread voices`.") }
        return id
    }

    private func validSpeed(_ raw: String) throws -> Float {
        guard let v = Float(raw), TalkReadCore.Settings.speedRange.contains(v) else { throw AppError.badArgs("Speed must be a number from 0.5 to 4.0.") }
        return v
    }

    // MARK: JSON shapes

    nonisolated static func name(_ s: ReadSession.State) -> String {
        switch s {
        case .preparing: return "preparing"
        case .playing: return "playing"
        case .paused: return "paused"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    nonisolated static func name(_ s: DictationController.State) -> String {
        switch s {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// A word list as rows sorted as the editor shows them.
    nonisolated static func wordListJSON(_ map: [String: String], key: String, value: String) -> JSONValue {
        .array(map.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { .object([key: .string($0.key), value: .string($0.value)]) })
    }

    nonisolated static func json(_ v: Voice) -> JSONValue {
        .object(["id": .string(v.id), "name": .string(v.name), "accent": .string(v.accent), "gender": .string(v.gender),
                 "engine": .string(v.engine.rawValue), "model": .string(v.engine.modelName), "language": .string(v.language),
                 "installed": .bool(v.installed)])
    }

    nonisolated static func json(_ m: ModelState) -> JSONValue {
        switch m {
        case .missing(let mb): return .object(["state": .string("missing"), "megabytes": .number(Double(mb))])
        case .downloading(let p): return .object(["state": .string("downloading"), "progress": .number(p)])
        case .ready: return .object(["state": .string("ready")])
        case .failed(let e): return .object(["state": .string("failed"), "error": .string(e)])
        }
    }
}
