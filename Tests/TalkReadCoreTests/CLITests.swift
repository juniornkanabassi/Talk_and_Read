import XCTest
@testable import TalkReadCore

/// Runs the compiled `TalkReadCLI` (TALKREAD_TEST_CLI, or the product beside the test bundle) against an in-process
/// ControlServer in a disposable TALKREAD_HOME. No app, no microphone, nothing outside /private/tmp/talkread-wp2-home.
final class CLITests: XCTestCase {
    private var home: URL!
    private var socket: URL { home.appendingPathComponent("control.sock") }
    private let mcpDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("mcp")

    override func setUpWithError() throws { home = try makeTestDir("cli") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func compiledCLI() throws -> URL {
        let url = ProcessInfo.processInfo.environment["TALKREAD_TEST_CLI"].map { URL(fileURLWithPath: $0) }
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TalkReadCLI")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("No compiled CLI at \(url.path); run `swift build` first or set TALKREAD_TEST_CLI.")
        }
        return url
    }

    struct Run { let code: Int32; let out: String; let err: String
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:] } }

    private func run(_ executable: URL, _ args: [String], stdin: String? = nil, cwd: URL? = nil, env: [String: String] = [:]) throws -> Run {
        let child = Process()
        child.executableURL = executable
        child.arguments = args
        child.environment = ProcessInfo.processInfo.environment.merging(["TALKREAD_HOME": home.path]) { $1 }.merging(env) { $1 }
        if let cwd { child.currentDirectoryURL = cwd }
        let out = home.appendingPathComponent("out-\(UUID().uuidString)"), err = home.appendingPathComponent("err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        child.standardOutput = try FileHandle(forWritingTo: out); child.standardError = try FileHandle(forWritingTo: err)
        let input = Pipe()
        child.standardInput = input
        try child.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        child.waitUntilExit()
        return Run(code: child.terminationStatus, out: try String(contentsOf: out, encoding: .utf8), err: try String(contentsOf: err, encoding: .utf8))
    }

    private func cli(_ args: [String], stdin: String? = nil, cwd: URL? = nil) throws -> Run {
        try run(compiledCLI(), args, stdin: stdin, cwd: cwd)
    }

    /// Echo server that records every request.
    private func startServer(_ seen: Recorder, delay: UInt64 = 0, response: ControlResponse = ControlResponse(ok: true, message: "done")) throws -> ControlServer {
        try ControlServer(path: socket) { r in
            seen.add(r)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return response
        }
    }

    // MARK: exit codes and output

    func testAppNotRunningExitsThree() throws {
        let human = try cli(["status"])
        XCTAssertEqual(human.code, 3)
        XCTAssertTrue(human.err.hasPrefix("app_not_running: "), human.err)
        XCTAssertTrue(human.err.contains("Open Talk and Read first"))
        let machine = try cli(["status", "--json"])
        XCTAssertEqual(machine.code, 3)
        XCTAssertEqual(machine.json["code"] as? String, "app_not_running")
    }

    func testHumanAndJSONOutput() throws {
        let seen = Recorder()
        let server = try startServer(seen, response: ControlResponse(ok: true, message: "Reading", data: ["state": "playing", "speed": 1.25, "queued": 3]))
        defer { server.stop() }
        let human = try cli(["status"])
        XCTAssertEqual(human.code, 0)
        XCTAssertEqual(human.out, "Reading\nqueued=3 speed=1.25 state=playing\n")
        let machine = try cli(["status", "--json"])
        XCTAssertEqual(machine.code, 0)
        XCTAssertEqual(machine.json["ok"] as? Bool, true)
        XCTAssertEqual((machine.json["data"] as? [String: Any])?["state"] as? String, "playing")
        XCTAssertEqual(machine.out.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 1, "--json prints one line")
    }

    func testAppErrorExitsOneWithCodeAndMessage() throws {
        let server = try startServer(Recorder(), response: ControlResponse(ok: false, code: "busy", message: "Agent 'mcp-1' is reading. Use --force to take over."))
        defer { server.stop() }
        let human = try cli(["speak", "hi"])
        XCTAssertEqual(human.code, 1)
        XCTAssertEqual(human.err, "busy: Agent 'mcp-1' is reading. Use --force to take over.\n")
        XCTAssertEqual(human.out, "")
        let machine = try cli(["speak", "hi", "--json"])
        XCTAssertEqual(machine.code, 1)
        XCTAssertEqual(machine.json["code"] as? String, "busy")
    }

    func testTextResultsPrintAsPlainText() throws {
        let server = try startServer(Recorder(), response: ControlResponse(ok: true, data: ["text": "Hello, world.", "words": 2]))
        defer { server.stop() }
        XCTAssertEqual(try cli(["dictation-last"]).out, "Hello, world.\n")
    }

    func testVoicesListing() throws {
        let voices: JSONValue = [["id": "af_heart", "name": "Heart", "accent": "American", "installed": true],
                                 ["id": "bf_emma", "name": "Emma", "accent": "British", "installed": false]]
        let server = try startServer(Recorder(), response: ControlResponse(ok: true, data: ["voices": voices]))
        defer { server.stop() }
        XCTAssertEqual(try cli(["voices"]).out, "af_heart  Heart  American\nbf_emma  Emma  British (not installed)\n")
    }

    // MARK: usage

    func testUsageErrorsExitTwo() throws {
        for args in [["nonsense"], ["speak"], ["speed"], ["speed", "fast"], ["skip", "x"], ["models", "explode"], ["status", "--bogus", "1"],
                     ["status", "extra"], ["voice"], ["settings-set", "speed"], ["status", "--force"], ["speak", "hi", "--speed"]] {
            let r = try cli(args)
            XCTAssertEqual(r.code, 2, "\(args): \(r.out) \(r.err)")
            XCTAssertTrue(r.err.hasPrefix("usage: "), "\(args): \(r.err)")
        }
        // A flag that follows a missing value is not swallowed as that value.
        for args in [["speak", "hi", "--voice", "--json"], ["--json"], ["--json", "nonsense"]] {
            let r = try cli(args)
            XCTAssertEqual(r.code, 2, "\(args)")
            XCTAssertEqual(r.json["code"] as? String, "usage", "\(args): \(r.out)")
        }
    }

    func testHelp() throws {
        let top = try cli(["--help"])
        XCTAssertEqual(top.code, 0)
        for name in ["status", "voices", "speak", "read-selection", "read-file", "pause", "resume", "stop", "skip", "speed", "voice", "dictate-start",
                     "dictate-stop", "dictation-last", "dictate-file", "open", "settings-get", "settings-set", "models"] {
            XCTAssertTrue(top.out.contains("  \(name) "), name)
            let one = try cli([name, "--help"])
            XCTAssertEqual(one.code, 0, name)
            XCTAssertTrue(one.out.contains("Example: talkread \(name)"), "\(name): \(one.out)")
        }
    }

    func testManifestListsOneToolPerCommand() throws {
        let manifest = try cli(["mcp-manifest"])
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifest.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(tools.count, 19)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, 19)
        let speak = try XCTUnwrap(tools.first { $0["name"] as? String == "speak" })
        let schema = try XCTUnwrap(speak["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["text"])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any])?.keys.map { $0 } ?? []), ["text", "voice", "speed", "force"])
        XCTAssertNotNil(tools.first { $0["name"] as? String == "dictate_file" })
        XCTAssertTrue(tools.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
    }

    // MARK: request mapping

    func testArgumentsReachTheApp() throws {
        let seen = Recorder()
        let server = try startServer(seen)
        defer { server.stop() }
        let cwd = home.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        _ = try cli(["speak", "Hello", "there", "world", "--voice", "bf_emma", "--speed=1.2", "--force", "--caller", "agent-7", "--request-id", "req-1"])
        _ = try cli(["speak", "--", "-5 degrees"])
        _ = try cli(["speak", "-"], stdin: "text from stdin\n")
        _ = try cli(["read-file", "docs/a.pdf"], cwd: cwd)
        _ = try cli(["dictate-file", "../b.wav"], cwd: cwd)
        _ = try cli(["skip"]); _ = try cli(["skip", "-2"]); _ = try cli(["speed", "1.5"]); _ = try cli(["voice", "bf_emma"])
        _ = try cli(["settings-set", "speed", "1.25"]); _ = try cli(["settings-get"]); _ = try cli(["settings-get", "voiceID"])
        _ = try cli(["models"]); _ = try cli(["models", "download"])
        let r = seen.requests
        XCTAssertEqual(r.count, 14)
        XCTAssertEqual(r[0].command, "speak")
        XCTAssertEqual(r[0].args, ["text": "Hello there world", "voice": "bf_emma", "speed": "1.2"])
        XCTAssertEqual(r[0].caller, "agent-7"); XCTAssertEqual(r[0].id, "req-1"); XCTAssertTrue(r[0].force)
        XCTAssertEqual(r[1].args, ["text": "-5 degrees"])
        XCTAssertFalse(r[1].force)
        XCTAssertEqual(r[2].args, ["text": "text from stdin\n"])
        XCTAssertTrue(r[1].caller.range(of: "^cli-\\d+$", options: .regularExpression) != nil, r[1].caller)
        XCTAssertNotEqual(r[1].id, r[2].id)
        XCTAssertEqual(r[3].args, ["path": cwd.appendingPathComponent("docs/a.pdf").standardizedFileURL.path])
        XCTAssertEqual(r[4].args, ["path": home.appendingPathComponent("b.wav").standardizedFileURL.path])
        XCTAssertEqual(r[5].args, ["sentences": "1"]); XCTAssertEqual(r[6].args, ["sentences": "-2"])
        XCTAssertEqual(r[7].args, ["value": "1.5"]); XCTAssertEqual(r[8].args, ["id": "bf_emma"])
        XCTAssertEqual(r[9].command, "settings-set"); XCTAssertEqual(r[9].args, ["key": "speed", "value": "1.25"])
        XCTAssertEqual(r[10].args, [:]); XCTAssertEqual(r[11].args, ["key": "voiceID"])
        XCTAssertEqual(r[12].args, ["action": "status"]); XCTAssertEqual(r[13].args, ["action": "download"])
    }

    func testOpenShowAndReadFlags() throws {
        let seen = Recorder()
        let server = try startServer(seen)
        defer { server.stop() }
        let doc = home.appendingPathComponent("a.pdf").standardizedFileURL.path
        _ = try cli(["open", doc])
        _ = try cli(["open", doc, "--show", "1", "--read=1"])
        XCTAssertEqual(try cli(["open", doc, "--show", "yes"]).code, 2)
        XCTAssertEqual(seen.requests.map(\.args), [["path": doc], ["path": doc, "show": "1", "read": "1"]])
        let manifest = try cli(["mcp-manifest"])
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifest.out.utf8)) as? [[String: Any]])
        let open = try XCTUnwrap(tools.first { $0["name"] as? String == "open" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set((open["properties"] as? [String: Any])?.keys.map { $0 } ?? []), ["path", "show", "read", "force"])
    }

    func testRetryWithTheSameRequestIdActsOnce() throws {
        let seen = Recorder()
        let server = try startServer(seen)
        defer { server.stop() }
        let args = ["speak", "hello", "--request-id", "retry-1", "--caller", "agent", "--json"]
        let first = try cli(args), second = try cli(args)
        XCTAssertEqual(seen.count, 1)
        XCTAssertNil((first.json["data"] as? [String: Any])?["replayed"])
        XCTAssertEqual((second.json["data"] as? [String: Any])?["replayed"] as? Bool, true)
        let changed = try cli(["speak", "different", "--request-id", "retry-1", "--caller", "agent", "--json"])
        XCTAssertEqual(changed.code, 1)
        XCTAssertEqual(changed.json["code"] as? String, "request_id_conflict")
    }

    func testTimeoutFlag() throws {
        let server = try startServer(Recorder(), delay: 2_000_000_000)
        defer { server.stop() }
        let r = try cli(["status", "--timeout", "0.4", "--json"])
        XCTAssertEqual(r.code, 1)
        XCTAssertEqual(r.json["code"] as? String, "timeout")
    }

    // MARK: MCP

    private func node(_ args: [String], env: [String: String] = [:]) throws -> Run {
        let which = try run(URL(fileURLWithPath: "/usr/bin/env"), ["which", "node"])
        guard which.code == 0 else { throw XCTSkip("node is not installed") }
        return try run(URL(fileURLWithPath: which.out.trimmingCharacters(in: .whitespacesAndNewlines)), args, env: env)
    }

    func testMCPAdapterAgainstAFakeCLI() throws {
        let r = try node([mcpDir.appendingPathComponent("test-mcp.mjs").path])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        XCTAssertTrue(r.out.contains("MCP adapter checks passed"), r.out)
    }

    func testMCPSyntax() throws {
        for script in ["talkread-mcp.mjs", "check-mcp.mjs", "test-mcp.mjs"] {
            let r = try node(["--check", mcpDir.appendingPathComponent(script).path])
            XCTAssertEqual(r.code, 0, "\(script): \(r.err)")
        }
    }

    /// The whole chain on a bundle-shaped folder: check-mcp.mjs -> adapter -> bundled helper -> socket -> server.
    func testCheckMCPAgainstABundleLayout() throws {
        let seen = Recorder()
        let server = try ControlServer(path: socket) { r in
            seen.add(r)
            return ControlResponse(ok: true, data: r.command == "voices" ? ["voices": [["id": "af_heart"]]] : ["state": "idle"])
        }
        defer { server.stop() }
        let app = home.appendingPathComponent("Fake.app/Contents", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Resources/mcp"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try fm.copyItem(at: mcpDir.appendingPathComponent("talkread-mcp.mjs"), to: app.appendingPathComponent("Resources/mcp/talkread-mcp.mjs"))
        try fm.copyItem(at: try compiledCLI(), to: app.appendingPathComponent("Helpers/talkread"))
        try fm.copyItem(at: mcpDir.deletingLastPathComponent().appendingPathComponent("Resources/Info.plist"), to: app.appendingPathComponent("Info.plist"))
        let r = try node([mcpDir.appendingPathComponent("check-mcp.mjs").path, home.appendingPathComponent("Fake.app").path])
        XCTAssertEqual(r.code, 0, r.out + r.err)
        XCTAssertTrue(r.out.contains("MCP check passed"), r.out)
        XCTAssertTrue(r.out.contains("initialize  version 0.1.0"), "version comes from the bundle's Info.plist: \(r.out)")
        XCTAssertEqual(seen.requests.map(\.command), ["status", "voices"])
        let callers = Set(seen.requests.map(\.caller))
        XCTAssertEqual(callers.count, 1)
        XCTAssertTrue(callers.first?.range(of: "^mcp-\\d+-[0-9a-f-]{36}$", options: .regularExpression) != nil, "\(callers)")
        // Without a server the same check must fail.
        server.stop()
        let down = try node([mcpDir.appendingPathComponent("check-mcp.mjs").path, home.appendingPathComponent("Fake.app").path])
        XCTAssertEqual(down.code, 1, down.out)
    }
}
