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
            return ["voices": .array(voices.map(Self.json)), "current": .string(settings.voiceID)]

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

        case "read-file":
            let url = try fileArg(a)
            try checkOwner(r.caller, force: r.force)
            let id = reserve(r.caller)
            let text: String
            do { text = try await Task.detached { try await Importer.load(url) }.value.text } catch {
                if owner?.sessionID == id { owner = nil }
                throw AppError(code: "failed", message: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard owner?.sessionID == id else { throw AppError(code: "superseded", message: "Another read started first.") }
            return try await firstAudio(startSession(text, capture: nil, id: id, source: "file"))

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
            guard let n = Int(a["sentences"] ?? "1") else { throw AppError.badArgs("sentences must be a whole number.") }
            try claim(r)
            guard let s = liveSession else { throw AppError(code: "not_reading", message: "Nothing is being read.") }
            s.skip(sentences: n)
            return ["sentences": .number(Double(n))]

        case "speed":
            guard let raw = a["value"] else { throw AppError.badArgs("speed needs a value from 0.5 to 3.0.") }
            let v = try validSpeed(raw)
            try claim(r)
            var next = settings
            next.speed = v
            settings = next.validated()
            return ["speed": .number(Double(settings.speed))]

        case "voice":
            guard let raw = a["id"] else { throw AppError.badArgs("voice needs an id; see `talkread voices`.") }
            let id = try validVoice(raw)
            try claim(r)
            settings.voiceID = id
            return ["voice": .string(id), "speaking": .string(voice(for: id).id)]

        case "dictate-start":
            try dictation.start(caller: r.caller, force: r.force)
            return ["state": .string(Self.name(dictation.state))]

        case "dictate-stop":
            try dictation.stop(insert: a["insert"] != "0", caller: r.caller, force: r.force)
            guard let text = await dictation.result() else {
                throw AppError(code: "failed", message: "The dictation was cancelled or could not be transcribed.")
            }
            return ["text": .string(text)]

        case "dictation-last":
            guard let e = dictation.history.first else { throw AppError(code: "empty", message: "Nothing has been dictated yet.") }
            return ["text": .string(e.text), "date": .string(ISO8601DateFormatter().string(from: e.date))]

        case "dictate-file":
            let url = try fileArg(a)
            let start = Date()
            let text = try await dictation.transcribe(file: url, caller: r.caller)
            return ["text": .string(text), "ms": .number((Date().timeIntervalSince(start) * 1000).rounded())]

        case "open":
            let url = try fileArg(a)
            let andRead = a["read"] == "1"
            var id: UUID?
            if andRead {
                try checkOwner(r.caller, force: r.force)
                id = reserve(r.caller)
            }
            let item: LibraryItem
            do { item = try await importFile(url) } catch {
                if let id, owner?.sessionID == id { owner = nil }
                throw AppError(code: "failed", message: "Could not open \(url.lastPathComponent): \(error.localizedDescription)")
            }
            WindowRouter.shared.open(item)                       // the reader shows it; no window comes forward
            if a["show"] == "1" { WindowRouter.shared.showMainWindow() }
            var data: [String: JSONValue] = ["id": .string(item.id.uuidString), "title": .string(item.title), "kind": .string(item.kind)]
            if let id {
                guard owner?.sessionID == id else { throw AppError(code: "superseded", message: "Another read started first.") }
                data.merge(try await firstAudio(startDocument(item, text: try documentText(item), fromToken: nil, id: id))) { $1 }
            }
            return data

        case "settings-get":
            let all = settings.json()
            guard let key = a["key"] else { return all }
            guard Settings.keys.contains(key) else { throw AppError.badArgs("Unknown setting '\(key)'. Keys: \(Settings.keys.joined(separator: ", ")).") }
            return [key: all[key] ?? .null]

        case "settings-set":
            guard let key = a["key"], let raw = a["value"] else { throw AppError.badArgs("settings-set needs a key and a value.") }
            var next = settings
            do { try next.set(key, to: raw) } catch let e as ControlError { throw AppError.badArgs(e.message) }
            if key == "voiceID" { _ = try validVoice(next.voiceID) }
            if key == "speed" || key == "voiceID" { try claim(r) }
            settings = next
            return [key: settings.json()[key] ?? .null]

        case "models":
            switch a["action"] ?? "status" {
            case "status": break
            case "download":
                downloadModels()
                await downloadTask?.value
            default: throw AppError.badArgs("models takes status or download.")
            }
            return ["voice": Self.json(voiceModel), "dictation": Self.json(dictationModel)]

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

    /// Waits up to 5 s for the first audio of a read the caller just started.
    private func firstAudio(_ s: ReadSession) async throws -> [String: JSONValue] {
        for _ in 0..<500 {
            if let ms = s.firstAudioMs { return ["firstAudioMs": .number(Double(ms)), "voice": .string(sessionInfo.voice)] }
            if case .failed(let m) = s.state { throw AppError(code: "failed", message: m) }
            if s.state == .finished { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ["firstAudioMs": .null, "state": .string(Self.name(s.state)), "voice": .string(sessionInfo.voice)]
    }

    func status() -> [String: JSONValue] {
        let s = session
        func num(_ v: Int?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
        let reading: [String: JSONValue] = [
            "state": .string(s.map { Self.name($0.state) } ?? "idle"),
            "caller": owner.map { .string($0.caller) } ?? .null,
            "token": num(s?.currentToken),
            "sentence": num(s?.currentSentence),
            "voice": .string(s == nil ? settings.voiceID : sessionInfo.voice),
            "speed": .number(Double(s == nil ? settings.speed : sessionInfo.rate)),
            "firstAudioMs": num(s?.firstAudioMs),
            "source": s == nil ? .null : .string(sessionInfo.source)
        ]
        return [
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "reading": .object(reading),
            "dictation": .object(["state": .string(Self.name(dictation.state)), "owner": dictation.owner.map { .string($0) } ?? .null]),
            "permissions": .object(["accessibility": .bool(permissions.accessibility), "microphone": .bool(permissions.microphone),
                                    "screenRecording": .bool(permissions.screenRecording)]),
            "models": .object(["voice": Self.json(voiceModel), "dictation": Self.json(dictationModel)])
        ]
    }

    // MARK: Argument checks

    private func fileArg(_ a: [String: String]) throws -> URL {
        guard let p = a["path"], !p.isEmpty else { throw AppError.badArgs("A file path is required.") }
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AppError.badArgs("No readable file at \(url.path).") }
        return url
    }

    private func validVoice(_ id: String) throws -> String {
        guard voices.contains(where: { $0.id == id }) else { throw AppError.badArgs("Unknown voice '\(id)'; see `talkread voices`.") }
        return id
    }

    private func validSpeed(_ raw: String) throws -> Float {
        guard let v = Float(raw), (0.5...3.0).contains(v) else { throw AppError.badArgs("Speed must be a number from 0.5 to 3.0.") }
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

    nonisolated static func json(_ v: Voice) -> JSONValue {
        .object(["id": .string(v.id), "name": .string(v.name), "accent": .string(v.accent), "gender": .string(v.gender),
                 "engine": .string(v.engine.rawValue), "installed": .bool(v.installed)])
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
