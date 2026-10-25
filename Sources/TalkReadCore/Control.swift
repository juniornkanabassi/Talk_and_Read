// AF_UNIX control socket: JSON command schema, server and client. Owned by WP2.
// Ported from ReadAlong's Control.swift (0600 socket, same-user check, deadlines) to the ESSENTIALS types, with
// concurrent handlers and a replay cache (PLAN decisions 11 and 20).
import Foundation
import Darwin

// MARK: Wire types

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { $1 }) }
    public init(nilLiteral: ()) { self = .null }
}

public struct ControlRequest: Codable, Sendable {
    /// Client UUID, reused on retry; replay key is (caller, id).
    public var id: String
    public var command: String
    public var args: [String: String]
    public var caller: String
    public var force: Bool
    public init(id: String = UUID().uuidString, command: String, args: [String: String] = [:], caller: String = "cli", force: Bool = false) {
        self.id = id; self.command = command; self.args = args; self.caller = caller; self.force = force
    }
    /// `id` and `command` are required; the rest default, so hand-written requests stay short.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
        caller = try c.decodeIfPresent(String.self, forKey: .caller) ?? "unknown"
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var data: [String: JSONValue]?
    public init(ok: Bool, code: String? = nil, message: String? = nil, data: [String: JSONValue]? = nil) {
        self.ok = ok; self.code = code; self.message = message; self.data = data
    }
}

/// Transport and validation errors (client side and server start-up). Server-side command failures are `ControlResponse`s.
public struct ControlError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

// MARK: Socket helpers

private func errnoError(_ code: String, _ path: String) -> ControlError {
    ControlError(code, "\(path): \(String(cString: strerror(errno)))")
}

private func makeAddress(_ path: String) -> (sockaddr_un, socklen_t)? {
    let bytes = Array(path.utf8)
    guard bytes.count <= 103 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
            dst[bytes.count] = 0
        }
    }
    return (address, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1))
}

private func connectSocket(_ address: sockaddr_un, _ length: socklen_t, fd: Int32) -> Bool {
    withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 } }
}

private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// Waits until `fd` is ready for `events`; false once the deadline passes.
private func wait(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) -> Bool {
    while true {
        let left = deadline - now()
        guard left > 0 else { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        let r = poll(&p, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
        if r > 0 { return true }
        if r < 0 && errno != EINTR { return false }
    }
}

/// Sends all of `data` on a non-blocking socket before the deadline.
private func writeAll(_ fd: Int32, _ data: Data, until deadline: TimeInterval) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var sent = 0
        while sent < raw.count {
            let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
            if n > 0 { sent += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) {
                guard wait(fd, Int16(POLLOUT), until: deadline) else { return false }
                continue
            }
            return false
        }
        return true
    }
}

/// Reads up to the first newline. Fails on timeout, close, or a line longer than `limit`.
private func readLine(_ fd: Int32, limit: Int, until deadline: TimeInterval) -> Result<Data, ControlError> {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        guard wait(fd, Int16(POLLIN), until: deadline) else { return .failure(ControlError("timeout", "Timed out waiting for a complete line.")) }
        let n = recv(fd, &buffer, buffer.count, 0)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        if n < 0 { return .failure(errnoError("socket_read_error", "recv")) }
        if n == 0 { return .failure(ControlError("closed", "The connection closed before a complete line arrived.")) }
        data.append(contentsOf: buffer[..<n])
        let newline = data.firstIndex(of: 10)
        if (newline.map { $0 - data.startIndex } ?? data.count) > limit {
            return .failure(ControlError("too_large", "Line exceeds \(limit) bytes."))
        }
        if let newline { return .success(data.prefix(upTo: newline)) }
    }
}

// MARK: Replay cache (PLAN decision 11)

/// Remembers the last 64 mutating (caller, id) keys for 5 minutes. The in-flight task is stored, so a duplicate that
/// arrives while the first is still running waits for it and replays its response. Lookup comes before eviction, and
/// only finished entries are evicted (oldest first, when a new key is admitted), so in-flight work always replays.
actor ReplayCache {
    private struct Entry { let fingerprint: Int; let task: Task<ControlResponse, Never>; var finished: Date? }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []   // admission order, oldest first
    private let ttl: TimeInterval, limit: Int

    init(ttl: TimeInterval = 300, limit: Int = 64) { self.ttl = ttl; self.limit = limit }

    func run(caller: String, id: String, fingerprint: Int, _ work: @escaping @Sendable () async -> ControlResponse) async -> ControlResponse {
        let key = caller + "\u{0}" + id
        let cutoff = Date().addingTimeInterval(-ttl)
        for k in order where entries[k]?.finished.map({ $0 < cutoff }) == true { drop(k) }
        if let entry = entries[key] {
            guard entry.fingerprint == fingerprint else {
                return ControlResponse(ok: false, code: "request_id_conflict",
                                       message: "Request id \(id) was already used by caller \(caller) for a different request. Use a new id.")
            }
            var response = await entry.task.value
            response.data = (response.data ?? [:]).merging(["replayed": .bool(true)]) { $1 }
            return response
        }
        // Room for the new key, oldest finished first; while every entry is still running the cache briefly exceeds the limit.
        while entries.count >= limit, let oldest = order.first(where: { entries[$0]?.finished != nil }) { drop(oldest) }
        let task = Task.detached { await work() }
        entries[key] = Entry(fingerprint: fingerprint, task: task, finished: nil)
        order.append(key)
        let response = await task.value
        // A refusal because another caller owns the session is not an effect: let the same id retry later.
        if response.code == "busy" { drop(key) } else { entries[key]?.finished = Date() }
        return response
    }

    private func drop(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }
}

// MARK: Server

public final class ControlServer: @unchecked Sendable {
    /// Commands that change state; only these are replay-protected.
    public static let mutatingCommands: Set<String> = [
        "speak", "read-selection", "read-file", "pause", "resume", "stop", "skip", "speed", "voice",
        "dictate-start", "dictate-stop", "dictate-file", "open", "settings-set", "models", "mic", "update-check",
        "dictate-cancel", "insert-again", "open-url", "read-pasted", "read-again", "library-open", "library-remove", "history-delete",
        "vocabulary-set", "vocabulary-remove", "vocabulary-suggestion", "pronunciation-set", "pronunciation-remove", "shortcuts-reset"
    ]
    static let maxRequest = 1_048_576
    static let maxResponse = 8_388_608

    private let path: String
    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    private let cache = ReplayCache()
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0

    /// Binds and starts listening at once. A stale socket file is replaced; a live one is refused (`already_running`).
    public init(path: URL, requestTimeout: TimeInterval = 5, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) throws {
        signal(SIGPIPE, SIG_IGN)   // a client that hangs up mid-reply must not kill the app (setsockopt fails on a closed peer)
        self.path = path.path
        self.handler = handler
        self.requestTimeout = requestTimeout
        let (listener, bound) = try Self.bind(self.path)
        inode = bound
        let readSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "local.talkread.control.accept"))
        readSource.setEventHandler { [weak self] in self?.acceptConnections(listener) }
        readSource.setCancelHandler { close(listener) }
        source = readSource
        readSource.resume()
    }

    public func stop() {
        lock.lock(); let current = source; source = nil; let mine = inode; inode = 0; lock.unlock()
        current?.cancel()
        var info = stat()
        if mine != 0, lstat(path, &info) == 0, info.st_ino == mine, (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    private static func bind(_ path: String) throws -> (Int32, ino_t) {
        guard let (address, length) = makeAddress(path) else {
            throw ControlError("socket_path_too_long", "Socket path must be at most 103 UTF-8 bytes.")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard chmod(parent, 0o700) == 0 else { throw errnoError("socket_directory_error", parent) }
        } catch let e as ControlError { throw e
        } catch { throw ControlError("socket_directory_error", "Cannot create \(parent): \(error.localizedDescription)") }

        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
                throw ControlError("socket_path_occupied", "A non-socket file already exists at \(path); remove it manually.")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw errnoError("socket_probe_error", path) }
            let live = connectSocket(address, length, fd: probe)
            let reason = errno
            close(probe)
            if live { throw ControlError("already_running", "A Talk & Read control server is already listening at \(path).") }
            if reason != ECONNREFUSED && reason != ENOENT {
                throw ControlError("socket_probe_error", "Cannot tell whether the socket is stale: \(String(cString: strerror(reason))).")
            }
            guard unlink(path) == 0 else { throw errnoError("socket_path_error", path) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errnoError("socket_error", path) }
        func fail(_ code: String) -> ControlError { let e = errnoError(code, path); close(fd); return e }
        let bound = withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
        guard bound == 0 else { throw fail("socket_bind_error") }
        guard chmod(path, 0o600) == 0, listen(fd, 32) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let e = fail("socket_listen_error"); unlink(path); throw e
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw fail("socket_stat_error") }
        return (fd, info.st_ino)
    }

    private func acceptConnections(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
    }

    /// One request per connection. Reading has a deadline; the handler has none (the client's timeout governs).
    private func serve(_ client: Int32) {
        // Darwin may pass the listener's O_NONBLOCK on; the helpers expect it.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        switch readLine(client, limit: Self.maxRequest, until: now() + requestTimeout) {
        case .failure(let e):
            let code = e.code == "too_large" ? "request_too_large" : e.code == "timeout" ? "request_timeout" : "bad_request"
            finish(client, ControlResponse(ok: false, code: code, message: e.message))
        case .success(let line):
            guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line), !request.id.isEmpty, !request.command.isEmpty else {
                return finish(client, ControlResponse(ok: false, code: "bad_request",
                                                      message: "Request must be a JSON object with string id and command."))
            }
            Task.detached { [self] in
                let response = await dispatch(request)
                DispatchQueue.global(qos: .userInitiated).async { self.finish(client, response) }
            }
        }
    }

    private func dispatch(_ request: ControlRequest) async -> ControlResponse {
        guard Self.mutatingCommands.contains(request.command) else { return await handler(request) }
        var hasher = Hasher()
        hasher.combine(request.command)
        for (key, value) in request.args.sorted(by: { $0.key < $1.key }) { hasher.combine(key); hasher.combine(value) }
        hasher.combine(request.force)
        let handler = self.handler
        return await cache.run(caller: request.caller, id: request.id, fingerprint: hasher.finalize()) { await handler(request) }
    }

    private func finish(_ client: Int32, _ response: ControlResponse) {
        defer { close(client) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(response)) ?? Data(#"{"ok":false,"code":"internal_error"}"#.utf8)
        if data.count > Self.maxResponse {
            data = Data(#"{"ok":false,"code":"response_too_large","message":"The reply is larger than the 8 MB limit."}"#.utf8)
        }
        _ = writeAll(client, data + Data([10]), until: now() + 5)
    }
}

// MARK: Client

public enum ControlClient {
    /// Sends one request and waits up to `timeout` seconds for the reply. Throws `ControlError`:
    /// `app_not_running` (no listener), `timeout`, `request_too_large`, `bad_response`, or a socket error.
    public static func send(_ r: ControlRequest, to path: URL, timeout: Double) throws -> ControlResponse {
        let socketPath = path.path
        guard let (address, length) = makeAddress(socketPath) else {
            throw ControlError("socket_path_too_long", "Socket path must be at most 103 UTF-8 bytes.")
        }
        guard var payload = try? JSONEncoder().encode(r) else { throw ControlError("bad_request", "Request is not encodable.") }
        guard payload.count <= ControlServer.maxRequest else { throw ControlError("request_too_large", "Request exceeds \(ControlServer.maxRequest) bytes.") }
        payload.append(10)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errnoError("socket_error", socketPath) }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard connectSocket(address, length, fd: fd) else {
            if errno == ENOENT || errno == ECONNREFUSED {
                throw ControlError("app_not_running", "Nothing is listening on \(socketPath). Open Talk & Read first.")
            }
            throw errnoError("socket_connect_error", socketPath)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = now() + timeout
        guard writeAll(fd, payload, until: deadline) else {
            throw ControlError("timeout", "Could not send the request to Talk & Read within \(Int(timeout)) s.")
        }
        switch readLine(fd, limit: ControlServer.maxResponse, until: deadline) {
        case .success(let line):
            guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else {
                throw ControlError("bad_response", "Talk & Read returned invalid JSON.")
            }
            return response
        case .failure(let e):
            switch e.code {
            case "timeout":
                throw ControlError("timeout", "No reply within \(Int(timeout)) s. The request may still be running; retry with the same request id to get its result.")
            case "too_large": throw ControlError("response_too_large", "Reply exceeds \(ControlServer.maxResponse) bytes.")
            default: throw ControlError("socket_read_error", "Talk & Read closed the connection before replying.")
            }
        }
    }
}
