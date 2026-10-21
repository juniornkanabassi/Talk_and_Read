import XCTest
import Darwin
@testable import TalkReadCore

/// Thread-safe log of what a test handler saw.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ControlRequest] = []
    func add(_ r: ControlRequest) { lock.lock(); items.append(r); lock.unlock() }
    var requests: [ControlRequest] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { requests.count }
}

/// A short temp directory (AF_UNIX paths are limited to 103 bytes) under /private/tmp/talkread-wp2-home.
func makeTestDir(_ prefix: String) throws -> URL {
    let dir = URL(fileURLWithPath: "/private/tmp/talkread-wp2-home/\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func echoResponse(_ r: ControlRequest) -> ControlResponse {
    ControlResponse(ok: true, data: ["command": .string(r.command), "caller": .string(r.caller), "n": .number(Double(r.args.count))])
}

/// ControlClient.send on a dispatch thread, so blocking clients never occupy the cooperative pool the server uses.
func clientSend(_ r: ControlRequest, _ path: URL, timeout: Double = 10) async throws -> ControlResponse {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try ControlClient.send(r, to: path, timeout: timeout) }) }
    }
}

/// Raw socket exchange: sends `bytes` as they are, then reads one reply line (nil if the server closed without one).
func rawExchange(_ path: URL, _ bytes: Data) -> ControlResponse? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let utf8 = Array(path.path.utf8)
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in utf8.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[utf8.count] = 0
        }
    }
    let connected = withUnsafePointer(to: address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)) }
    }
    guard connected == 0 else { return nil }
    bytes.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
    }
    var line = Data(), byte: UInt8 = 0
    while true {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 5000) > 0, recv(fd, &byte, 1, 0) == 1 else { break }
        if byte == 10 { break }
        line.append(byte)
    }
    return try? JSONDecoder().decode(ControlResponse.self, from: line)
}

final class ControlTests: XCTestCase {
    private var dir: URL!
    private var socketPath: URL { dir.appendingPathComponent("control.sock") }

    override func setUpWithError() throws { dir = try makeTestDir("ctl") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRoundTripAndPermissions() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in seen.add(r); return ControlResponse(ok: true, message: "hi", data: ["args": .object(r.args.mapValues { .string($0) })]) }
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(socketPath.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual((info.st_mode & S_IFMT), S_IFSOCK)
        XCTAssertEqual(lstat(dir.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let reply = try await clientSend(ControlRequest(id: "a", command: "voice", args: ["id": "bf_emma"], caller: "t", force: true), socketPath)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.message, "hi")
        XCTAssertEqual(reply.data?["args"], .object(["id": "bf_emma"]))
        XCTAssertEqual(seen.requests.first?.force, true)
        XCTAssertEqual(seen.requests.first?.caller, "t")
        XCTAssertNil(reply.data?["replayed"])
    }

    func testTenConcurrentClients() async throws {
        let server = try ControlServer(path: socketPath) { r in echoResponse(r) }
        defer { server.stop() }
        let path = socketPath
        let replies = try await withThrowingTaskGroup(of: (Int, ControlResponse).self) { group -> [Int: ControlResponse] in
            for i in 0..<10 {
                group.addTask { (i, try await clientSend(ControlRequest(id: "id-\(i)", command: i.isMultiple(of: 2) ? "status" : "speak", args: ["k": "v"], caller: "c\(i)"), path)) }
            }
            var out: [Int: ControlResponse] = [:]
            for try await (i, r) in group { out[i] = r }
            return out
        }
        XCTAssertEqual(replies.count, 10)
        for (i, r) in replies {
            XCTAssertEqual(r.data?["caller"], .string("c\(i)"))
            XCTAssertEqual(r.data?["command"], .string(i.isMultiple(of: 2) ? "status" : "speak"))
        }
    }

    func testRetryWithSameIdReplaysOnce() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in seen.add(r); return ControlResponse(ok: true, data: ["firstAudioMs": 120]) }
        defer { server.stop() }
        let request = ControlRequest(id: "same", command: "speak", args: ["text": "hi"], caller: "agent")
        let first = try await clientSend(request, socketPath)
        let second = try await clientSend(request, socketPath)
        XCTAssertEqual(seen.count, 1)
        XCTAssertNil(first.data?["replayed"])
        XCTAssertEqual(second.data?["replayed"], .bool(true))
        XCTAssertEqual(second.data?["firstAudioMs"], .number(120))
    }

    func testTwoCallersReusingAnIdBothExecute() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in seen.add(r); return ControlResponse(ok: true, data: ["command": .string(r.command)]) }
        defer { server.stop() }
        let a = try await clientSend(ControlRequest(id: "1", command: "speak", args: ["text": "x"], caller: "mcp-1-aaa"), socketPath)
        let b = try await clientSend(ControlRequest(id: "1", command: "pause", caller: "mcp-2-bbb"), socketPath)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(a.data?["command"], .string("speak"))
        XCTAssertEqual(b.data?["command"], .string("pause"))
        XCTAssertNil(b.data?["replayed"])
    }

    func testReusedIdWithDifferentContentConflicts() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in seen.add(r); return ControlResponse(ok: true) }
        defer { server.stop() }
        _ = try await clientSend(ControlRequest(id: "x", command: "speak", args: ["text": "one"], caller: "c"), socketPath)
        for changed in [ControlRequest(id: "x", command: "speak", args: ["text": "two"], caller: "c"),
                        ControlRequest(id: "x", command: "stop", caller: "c"),
                        ControlRequest(id: "x", command: "speak", args: ["text": "one"], caller: "c", force: true)] {
            let r = try await clientSend(changed, socketPath)
            XCTAssertFalse(r.ok)
            XCTAssertEqual(r.code, "request_id_conflict")
        }
        XCTAssertEqual(seen.count, 1)
    }

    func testConcurrentDuplicateWaitsForTheFirstThenReplays() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in
            seen.add(r)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return ControlResponse(ok: true, data: ["done": true])
        }
        defer { server.stop() }
        let request = ControlRequest(id: "dup", command: "dictate-file", args: ["path": "/x.wav"], caller: "c")
        let path = socketPath
        async let first = clientSend(request, path)
        try await Task.sleep(nanoseconds: 150_000_000)
        async let second = clientSend(request, path)
        let (a, b) = try await (first, second)
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(a.ok && b.ok)
        XCTAssertEqual(a.data?["replayed"] == nil, true)
        XCTAssertEqual(b.data?["replayed"], .bool(true))
        XCTAssertEqual(b.data?["done"], .bool(true))
    }

    func testQueryCommandsAreNotCached() async throws {
        let seen = Recorder()
        let server = try ControlServer(path: socketPath) { r in seen.add(r); return ControlResponse(ok: true) }
        defer { server.stop() }
        for _ in 0..<2 { _ = try await clientSend(ControlRequest(id: "q", command: "status", caller: "c"), socketPath) }
        XCTAssertEqual(seen.count, 2)
    }

    func testSlowRequestDoesNotDelayAnotherCaller() async throws {
        let server = try ControlServer(path: socketPath) { r in
            if r.command == "speak" { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            return ControlResponse(ok: true, data: ["command": .string(r.command)])
        }
        defer { server.stop() }
        let path = socketPath
        let start = Date()
        async let slow = clientSend(ControlRequest(id: "s", command: "speak", args: ["text": "long"], caller: "a"), path)
        try await Task.sleep(nanoseconds: 100_000_000)
        let fast = try await clientSend(ControlRequest(id: "f", command: "status", caller: "b"), path)
        let fastTime = Date().timeIntervalSince(start)
        XCTAssertTrue(fast.ok)
        XCTAssertLessThan(fastTime, 0.6, "a fast request waited behind a slow one")
        _ = try await slow
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.95)
    }

    func testOversizeAndMalformedRequests() throws {
        let server = try ControlServer(path: socketPath) { _ in ControlResponse(ok: true) }
        defer { server.stop() }
        let big = rawExchange(socketPath, Data(repeating: 65, count: ControlServer.maxRequest + 1))
        XCTAssertEqual(big?.code, "request_too_large")
        XCTAssertEqual(rawExchange(socketPath, Data("{nope}\n".utf8))?.code, "bad_request")
        XCTAssertEqual(rawExchange(socketPath, Data(#"{"command":"status"}"#.utf8 + [10]))?.code, "bad_request") // no id
        // Only id and command are required.
        XCTAssertEqual(rawExchange(socketPath, Data(#"{"id":"1","command":"status"}"#.utf8 + [10]))?.ok, true)
    }

    func testTricklingClientIsCutOffAtTheDeadline() throws {
        let server = try ControlServer(path: socketPath, requestTimeout: 0.5) { _ in ControlResponse(ok: true) }
        defer { server.stop() }
        let start = Date()
        // One byte at a time would keep a per-read timeout alive for ever; the whole request has one deadline.
        var reply: ControlResponse?
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in utf8.enumerated() { dst[i] = CChar(bitPattern: b) }; dst[utf8.count] = 0 } }
        XCTAssertEqual(withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)) } }, 0)
        var byte: UInt8 = 123
        var line = Data()
        while Date().timeIntervalSince(start) < 3 {
            _ = send(fd, &byte, 1, 0)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) > 0 {
                var c: UInt8 = 0
                while recv(fd, &c, 1, 0) == 1 { if c == 10 { break }; line.append(c) }
                reply = try? JSONDecoder().decode(ControlResponse.self, from: line)
                break
            }
        }
        XCTAssertEqual(reply?.code, "request_timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStaleSocketIsReplacedAndLiveOneIsRefused() throws {
        // A socket file left behind by a crashed app: bound, never listened on.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in utf8.enumerated() { dst[i] = CChar(bitPattern: b) }; dst[utf8.count] = 0 } }
        XCTAssertEqual(withUnsafePointer(to: address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(stale, $0, socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)) } }, 0)
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))
        let server = try ControlServer(path: socketPath) { _ in ControlResponse(ok: true, message: "new") }
        XCTAssertEqual(rawExchange(socketPath, Data(#"{"id":"1","command":"status"}"#.utf8 + [10]))?.message, "new")
        XCTAssertThrowsError(try ControlServer(path: socketPath) { _ in ControlResponse(ok: true) }) {
            XCTAssertEqual(($0 as? ControlError)?.code, "already_running")
        }
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath.path), "stop() removes its socket")
        // A regular file is never deleted.
        try Data("keep".utf8).write(to: socketPath)
        XCTAssertThrowsError(try ControlServer(path: socketPath) { _ in ControlResponse(ok: true) }) {
            XCTAssertEqual(($0 as? ControlError)?.code, "socket_path_occupied")
        }
        XCTAssertEqual(try String(contentsOf: socketPath, encoding: .utf8), "keep")
    }

    func testClientErrors() async throws {
        do { _ = try ControlClient.send(ControlRequest(command: "status"), to: socketPath, timeout: 1); XCTFail("expected an error") }
        catch let e as ControlError { XCTAssertEqual(e.code, "app_not_running") }
        let server = try ControlServer(path: socketPath) { _ in try? await Task.sleep(nanoseconds: 1_500_000_000); return ControlResponse(ok: true) }
        defer { server.stop() }
        do { _ = try await clientSend(ControlRequest(command: "status"), socketPath, timeout: 0.3); XCTFail("expected a timeout") }
        catch let e as ControlError { XCTAssertEqual(e.code, "timeout") }
        let huge = ControlRequest(command: "speak", args: ["text": String(repeating: "x", count: ControlServer.maxRequest)])
        do { _ = try ControlClient.send(huge, to: socketPath, timeout: 1); XCTFail("expected request_too_large") }
        catch let e as ControlError { XCTAssertEqual(e.code, "request_too_large") }
    }

    func testReplayCacheExpiresAndKeepsOnlyTheNewest() async {
        let cache = ReplayCache(ttl: 0.2, limit: 3)
        let calls = Recorder()
        func run(_ id: String) async -> ControlResponse {
            await cache.run(caller: "c", id: id, fingerprint: 1) { calls.add(ControlRequest(id: id, command: "x")); return ControlResponse(ok: true) }
        }
        _ = await run("a"); _ = await run("a")
        XCTAssertEqual(calls.count, 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await run("a")
        XCTAssertEqual(calls.count, 2, "an entry older than the ttl runs again")
        _ = await run("b"); _ = await run("c"); _ = await run("d")   // limit 3: "a" is evicted
        _ = await run("a")
        XCTAssertEqual(calls.requests.filter { $0.id == "a" }.count, 3)
    }

    /// Sol #10: the lookup used to run after eviction, so a retry of the oldest of 64 keys executed again.
    func testRetryOfTheOldestOf64Replays() async {
        let cache = ReplayCache()
        let calls = Recorder()
        func run(_ id: String) async -> ControlResponse {
            await cache.run(caller: "c", id: id, fingerprint: 1) { calls.add(ControlRequest(id: id, command: "x")); return ControlResponse(ok: true) }
        }
        for i in 0..<64 { _ = await run("k\(i)") }
        let retry = await run("k0")
        XCTAssertEqual(calls.count, 64, "the retry ran again")
        XCTAssertEqual(retry.data?["replayed"], .bool(true))
        _ = await run("k64")                                   // a new key evicts the oldest finished one
        _ = await run("k0")
        XCTAssertEqual(calls.requests.filter { $0.id == "k0" }.count, 2)
    }

    /// Sol #10: newer keys arriving during a long request must never evict it; its retry waits and replays.
    func testEvictionNeverDropsInFlightWork() async throws {
        let cache = ReplayCache(limit: 3)
        let calls = Recorder()
        func run(_ id: String, slow: Bool = false) async -> ControlResponse {
            await cache.run(caller: "c", id: id, fingerprint: 1) {
                calls.add(ControlRequest(id: id, command: "x"))
                if slow { try? await Task.sleep(nanoseconds: 500_000_000) }
                return ControlResponse(ok: true, data: ["id": .string(id)])
            }
        }
        async let long = run("long", slow: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        for id in ["a", "b", "c", "d", "e"] { _ = await run(id) }   // well past the limit while "long" runs
        let retry = await run("long", slow: true)
        let first = await long
        XCTAssertEqual(calls.requests.filter { $0.id == "long" }.count, 1, "the in-flight request ran twice")
        XCTAssertEqual(retry.data?["replayed"], .bool(true))
        XCTAssertEqual(retry.data?["id"], first.data?["id"])
        _ = await run("a")                                     // finished keys are still evicted oldest first
        XCTAssertEqual(calls.requests.filter { $0.id == "a" }.count, 2)
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["s": "x", "n": 1.5, "b": true, "z": nil, "a": [1, "two", false], "o": ["k": "v"]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)), .bool(true))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data("2".utf8)), .number(2))
    }
}
