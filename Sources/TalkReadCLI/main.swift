// `talkread` helper (Contents/Helpers/talkread): one subcommand per control command. Owned by WP2.
// Exit codes: 0 ok, 1 the app refused or failed, 2 usage, 3 Talk and Read is not running.
import Foundation
import TalkReadCore

// MARK: Command table (also the source of the MCP tool list: `talkread mcp-manifest`)

enum Kind { case string, number, integer, path }
struct Param {
    let name: String
    let kind: Kind
    let help: String
    var required = false
    var positional = false
    var variadic = false          // takes every remaining positional, joined by spaces
    var choices: [String]?
    var defaultValue: String?     // sent when the caller gives nothing
}
struct Command {
    let name: String
    let summary: String
    let example: String
    var params: [Param] = []
    var forceable = false         // may take --force (override another caller's active read or dictation)
    var timeout: Double = 30
}

let commands: [Command] = [
    Command(name: "status", summary: "Report reading, dictation, model and permission state.", example: "status"),
    Command(name: "voices", summary: "List the available voices and whether each is installed.", example: "voices"),
    Command(name: "speak", summary: "Read text aloud. Use - to read the text from standard input.", example: "speak \"Hello there\" --voice bf_emma --speed 1.2",
            params: [Param(name: "text", kind: .string, help: "Text to read.", required: true, positional: true, variadic: true),
                     Param(name: "voice", kind: .string, help: "Voice id, for example af_heart or bf_emma."),
                     Param(name: "speed", kind: .number, help: "Speed from 0.5 to 3.0.")], forceable: true),
    Command(name: "read-selection", summary: "Read the text currently selected in the frontmost app.", example: "read-selection", forceable: true),
    Command(name: "read-file", summary: "Read a document (PDF, TXT, MD, RTF, DOCX, HTML, EPUB) aloud.", example: "read-file ~/Documents/notes.pdf",
            params: [Param(name: "path", kind: .path, help: "File to read.", required: true, positional: true)], forceable: true),
    Command(name: "pause", summary: "Pause the current read.", example: "pause", forceable: true),
    Command(name: "resume", summary: "Resume a paused read.", example: "resume", forceable: true),
    Command(name: "stop", summary: "Stop the current read.", example: "stop", forceable: true),
    Command(name: "skip", summary: "Skip forward (or back, if negative) by sentences.", example: "skip 2",
            params: [Param(name: "sentences", kind: .integer, help: "Sentences to skip; default 1.", positional: true, defaultValue: "1")], forceable: true),
    Command(name: "speed", summary: "Set the reading speed, 0.5 to 3.0.", example: "speed 1.5",
            params: [Param(name: "value", kind: .number, help: "Speed from 0.5 to 3.0.", required: true, positional: true)], forceable: true),
    Command(name: "voice", summary: "Switch the reading voice.", example: "voice bf_emma",
            params: [Param(name: "id", kind: .string, help: "Voice id from `talkread voices`.", required: true, positional: true)], forceable: true),
    Command(name: "dictate-start", summary: "Start dictating from the microphone.", example: "dictate-start", forceable: true),
    Command(name: "dictate-stop", summary: "Stop dictating and insert the text where the cursor is.", example: "dictate-stop", forceable: true),
    Command(name: "dictation-last", summary: "Print the most recent dictation.", example: "dictation-last"),
    Command(name: "dictate-file", summary: "Transcribe an audio file (WAV, M4A) without the microphone.", example: "dictate-file ~/Desktop/note.m4a",
            params: [Param(name: "path", kind: .path, help: "Audio file to transcribe.", required: true, positional: true)], forceable: true, timeout: 600),
    Command(name: "open", summary: "Open a document in the Talk and Read reader.", example: "open ~/Documents/notes.pdf --show 1 --read 1",
            params: [Param(name: "path", kind: .path, help: "Document to open.", required: true, positional: true),
                     Param(name: "show", kind: .string, help: "1 brings the main window forward; default 0 (no focus change).", choices: ["0", "1"]),
                     Param(name: "read", kind: .string, help: "1 also starts reading it aloud; default 0.", choices: ["0", "1"])], forceable: true),
    Command(name: "settings-get", summary: "Read one setting, or all of them.", example: "settings-get speed",
            params: [Param(name: "key", kind: .string, help: "Setting name, for example speed or voiceID.", positional: true)]),
    Command(name: "settings-set", summary: "Change a setting.", example: "settings-set speed 1.25",
            params: [Param(name: "key", kind: .string, help: "Setting name.", required: true, positional: true),
                     Param(name: "value", kind: .string, help: "New value.", required: true, positional: true)], forceable: true),
    Command(name: "models", summary: "Show speech model status, or download the models (about 1 GB).", example: "models download",
            params: [Param(name: "action", kind: .string, help: "status or download; default status.", positional: true,
                           choices: ["status", "download"], defaultValue: "status")])
]

// MARK: Output

var json = false
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

func printJSON(_ response: ControlResponse) {
    if let data = try? encoder.encode(response), let line = String(data: data, encoding: .utf8) { print(line) }
}

func stderrLine(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func fail(_ code: String, _ message: String, exit status: Int32) -> Never {
    if json { printJSON(ControlResponse(ok: false, code: code, message: message)) } else { stderrLine("\(code): \(message)") }
    exit(status)
}

func usage(_ message: String, _ command: Command?) -> Never {
    fail("usage", message + " Try: talkread \(command?.name ?? "") --help", exit: 2)
}

func scalar(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "none"
    case .array(let a): return "[\(a.count) items]"
    case .object(let o): return "{" + o.keys.sorted().joined(separator: ",") + "}"
    }
}

/// One or two lines: the message, then the main values. Text results (dictations) print as plain text so they pipe.
func render(_ response: ControlResponse, command: String) {
    let data = (response.data ?? [:]).filter { $0.key != "replayed" }
    if let text = data["text"]?.stringValue { print(text); return }
    if command == "voices", let voices = data["voices"]?.arrayValue {
        for v in voices {
            guard let o = v.objectValue, let id = o["id"]?.stringValue else { continue }
            let rest = ["name", "accent", "gender", "engine"].compactMap { o[$0]?.stringValue }
            let installed = o["installed"]?.boolValue == false ? " (not installed)" : ""
            print(([id] + rest).joined(separator: "  ") + installed)
        }
        return
    }
    print(response.message ?? "ok")
    if !data.isEmpty { print(data.sorted { $0.key < $1.key }.map { "\($0.key)=\(scalar($0.value))" }.joined(separator: " ")) }
}

func help(_ command: Command? = nil) {
    guard let command else {
        print("talkread <command> [options]   Control Talk and Read from the shell. The app must be open.")
        for c in commands { print("  \(c.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.summary)") }
        print("Global options: --json  --force  --caller <name>  --request-id <uuid>  --timeout <seconds>  --help")
        print("Exit codes: 0 ok, 1 the app refused or failed, 2 usage, 3 Talk and Read is not running.")
        print("Run `talkread <command> --help` for one command with an example.")
        return
    }
    let positional = command.params.filter(\.positional).map { p in
        let label = p.variadic ? "\(p.name)…" : p.name
        return p.required ? "<\(label)>" : "[\(label)]"
    }
    let flags = command.params.filter { !$0.positional }.map { "[--\($0.name) <\($0.name)>]" }
    print((["talkread", command.name] + positional + flags).joined(separator: " ") + " [--json]" + (command.forceable ? " [--force]" : ""))
    print(command.summary)
    for p in command.params {
        print("  \(p.positional ? p.name : "--" + p.name)\(p.required ? " (required)" : ""): \(p.help)\(p.choices.map { " One of: " + $0.joined(separator: ", ") + "." } ?? "")")
    }
    if command.forceable { print("  --force: take over even if another caller (an agent, for example) is reading or dictating.") }
    print("  --json: print the app's reply as one line of JSON.  --caller, --request-id, --timeout: see `talkread --help`.")
    print("Example: talkread \(command.example)")
}

func manifest() {
    func schema(_ p: Param) -> [String: Any] {
        var s: [String: Any] = ["type": p.kind == .number ? "number" : p.kind == .integer ? "integer" : "string", "description": p.help]
        if let c = p.choices { s["enum"] = c }
        return s
    }
    let tools: [[String: Any]] = commands.map { c in
        var properties = Dictionary(uniqueKeysWithValues: c.params.map { ($0.name, schema($0)) })
        if c.forceable { properties["force"] = ["type": "boolean", "description": "Take over even if another caller is reading or dictating."] }
        return ["name": c.name.replacingOccurrences(of: "-", with: "_"), "description": c.summary,
                "inputSchema": ["type": "object", "properties": properties, "required": c.params.filter(\.required).map(\.name),
                                "additionalProperties": false] as [String: Any]]
    }
    print(String(decoding: try! JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]), as: UTF8.self))
}

// MARK: Parse

let argv = Array(CommandLine.arguments.dropFirst())
func isNegativeNumber(_ s: String) -> Bool { s.hasPrefix("-") && s.count > 1 && Double(s) != nil }

json = argv.contains("--json")   // so usage errors are JSON even when --json comes after the mistake
var force = false, wantHelp = false
var caller: String?, requestID: String?, timeoutOverride: Double?
var flags: [(name: String, value: String)] = []
var positionals: [String] = []
var index = 0
var literal = false
while index < argv.count {
    let arg = argv[index]; index += 1
    if literal || !arg.hasPrefix("-") || arg == "-" || isNegativeNumber(arg) { positionals.append(arg); continue }
    if arg == "--" { literal = true; continue }
    if arg == "-h" { wantHelp = true; continue }
    guard arg.hasPrefix("--") else { usage("Unknown option \(arg).", nil) }
    let parts = arg.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(parts[0])
    switch name {
    case "json": json = true; continue
    case "force": force = true; continue
    case "help": wantHelp = true; continue
    default: break
    }
    let value: String
    if parts.count == 2 { value = String(parts[1]) }
    else if index < argv.count, !argv[index].hasPrefix("--") { value = argv[index]; index += 1 }
    else { usage("Missing value for --\(name).", nil) }
    switch name {
    case "caller": caller = value
    case "request-id": requestID = value
    case "timeout":
        guard let t = Double(value), t > 0 else { usage("--timeout must be a positive number of seconds.", nil) }
        timeoutOverride = t
    default: flags.append((name, value))
    }
}

guard let first = positionals.first else {
    if wantHelp || argv.isEmpty { help(); exit(0) }
    usage("Missing command.", nil)
}
if first == "mcp-manifest" { manifest(); exit(0) }
guard let command = commands.first(where: { $0.name == first }) else { usage("Unknown command \(first).", nil) }
if wantHelp { help(command); exit(0) }
if force && !command.forceable { usage("\(command.name) does not take --force.", command) }

var values: [String: String] = [:]
for (name, value) in flags {
    guard command.params.contains(where: { $0.name == name }) else { usage("Unknown option --\(name).", command) }
    guard values[name] == nil else { usage("Repeated --\(name).", command) }
    values[name] = value
}
var rest = Array(positionals.dropFirst())
for p in command.params where p.positional && !rest.isEmpty {
    guard values[p.name] == nil else { usage("\(p.name) given twice.", command) }
    if p.variadic { values[p.name] = rest.joined(separator: " "); rest = [] }
    else { values[p.name] = rest.removeFirst() }
}
if let extra = rest.first { usage("Unexpected argument \(extra).", command) }

var args: [String: String] = [:]
for p in command.params {
    guard var value = values[p.name] ?? p.defaultValue else {
        if p.required { usage("Missing \(p.name).", command) }
        continue
    }
    if p.name == "text" && value == "-" { value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    switch p.kind {
    case .number: guard let n = Double(value), n.isFinite else { usage("\(p.name) must be a number.", command) }
    case .integer: guard Int(value) != nil else { usage("\(p.name) must be a whole number.", command) }
    case .path: value = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
    case .string: break
    }
    if let choices = p.choices, !choices.contains(value) { usage("\(p.name) must be one of: \(choices.joined(separator: ", ")).", command) }
    if p.required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { usage("\(p.name) is empty.", command) }
    args[p.name] = value
}

// MARK: Run

let longRunning = command.name == "models" && args["action"] == "download"
let request = ControlRequest(id: requestID ?? UUID().uuidString, command: command.name, args: args,
                             caller: caller ?? "cli-\(getppid())", force: force)
do {
    let response = try ControlClient.send(request, to: Paths.controlSocket,
                                          timeout: timeoutOverride ?? (longRunning ? 600 : command.timeout))
    if json { printJSON(response) }
    else if response.ok { render(response, command: command.name) }
    else { stderrLine("\(response.code ?? "error"): \(response.message ?? "The request failed.")") }
    exit(response.ok ? 0 : 1)
} catch let error as ControlError {
    fail(error.code, error.message, exit: error.code == "app_not_running" ? 3 : 1)
} catch {
    fail("failed", error.localizedDescription, exit: 1)
}
