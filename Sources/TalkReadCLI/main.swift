// `talkread` helper (Contents/Helpers/talkread): one subcommand per control command. Owned by WP2.
// Exit codes: 0 ok, 1 the app refused or failed, 2 usage, 3 Talk & Read is not running and could not be started.
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
    var confirm = false           // removes something for good: refused without --yes
}

let commands: [Command] = [
    Command(name: "status", summary: "Report reading, dictation, model and permission state.", example: "status"),
    Command(name: "voices", summary: "List the voices with their model (Kokoro, Qwen3), language (en, fr), gender and whether each is installed, and the current English and French voices.", example: "voices"),
    Command(name: "speak", summary: "Read text aloud: French text with the French voice, anything else with the English voice. Use - to read the text from standard input.",
            example: "speak \"Hello there\" --voice bf_emma --speed 1.2",
            params: [Param(name: "text", kind: .string, help: "Text to read.", required: true, positional: true, variadic: true),
                     Param(name: "voice", kind: .string, help: "Voice id for this read only, for example af_heart, qwen.us_warm or ff_siwis; overrides the language choice."),
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
    Command(name: "voice", summary: "Choose the reading voice from the next read on. A French voice (ff_siwis, qwen.fr_warm) becomes the French voice; any other the English voice.",
            example: "voice qwen.us_warm",
            params: [Param(name: "id", kind: .string, help: "Voice id from `talkread voices`, for example af_heart, bf_emma, qwen.us_warm, ff_siwis or qwen.fr_warm.", required: true, positional: true)], forceable: true),
    Command(name: "mic", summary: "List the microphones dictation can use, marking the system default and the chosen one; with a UID (or default) choose the microphone for the next dictation. A choice never interrupts a recording in progress.",
            example: "mic default",
            params: [Param(name: "uid", kind: .string, help: "UID from `talkread mic`, or default for whatever macOS has as the default input. Leave out to list.", positional: true)]),
    Command(name: "dictate-start", summary: "Start dictating from the microphone.", example: "dictate-start", forceable: true),
    Command(name: "dictate-stop", summary: "Stop dictating and insert the text where the cursor is.", example: "dictate-stop", forceable: true),
    Command(name: "dictate-cancel", summary: "Cancel the dictation in progress, as Esc does: nothing is typed or kept.", example: "dictate-cancel", forceable: true),
    Command(name: "insert-again", summary: "Type a dictation again where the cursor is in the frontmost app, as the Dictation page's Insert Again does. Without an id, the most recent dictation (Paste last transcript). Password fields are refused.",
            example: "insert-again 0F8E2C1A-4B7D-4E3A-9C55-1D2E3F4A5B6C",
            params: [Param(name: "id", kind: .string, help: "Dictation id from `talkread history --kind dictated`; default the most recent.", positional: true)], forceable: true),
    Command(name: "dictation-last", summary: "Print the most recent dictation.", example: "dictation-last"),
    Command(name: "history", summary: "List what was read aloud and what was dictated, newest first, as the Home page's History shows it. Read-only. Each entry has id (for history-delete, read-again and insert-again), kind (read or dictated), date (ISO 8601), app, bundleID (null for old entries) and text. Reads started inside Talk & Read have the app Talk & Read. truncated is true when very long texts made the reply stop short of the limit; ask for fewer entries or narrow the search.",
            example: "history --kind dictated --search ferry --limit 10 --json",
            params: [Param(name: "kind", kind: .string, help: "all, read or dictated; default all.", choices: ["all", "read", "dictated"]),
                     Param(name: "limit", kind: .integer, help: "Most entries to return, 1 to 500; default 50."),
                     Param(name: "search", kind: .string, help: "Only entries whose text or app name contains this, ignoring case.")]),
    Command(name: "history-delete", summary: "Delete one History entry (a read or a dictation) from this Mac for good, as the row's Delete does. Needs --yes.",
            example: "history-delete 0F8E2C1A-4B7D-4E3A-9C55-1D2E3F4A5B6C --yes",
            params: [Param(name: "id", kind: .string, help: "Entry id from `talkread history`.", required: true, positional: true),
                     Param(name: "kind", kind: .string, help: "read or dictated; only needed if a read and a dictation share the id.", choices: ["read", "dictated"])],
            confirm: true),
    Command(name: "read-again", summary: "Read a History entry aloud again, as the row's Read again does. Without an id, the most recent read (the menu's Replay last).",
            example: "read-again",
            params: [Param(name: "id", kind: .string, help: "Read id from `talkread history --kind read`; default the most recent.", positional: true)], forceable: true),
    Command(name: "dictate-file", summary: "Transcribe an audio file (WAV, M4A) without the microphone.", example: "dictate-file ~/Desktop/note.m4a",
            params: [Param(name: "path", kind: .path, help: "Audio file to transcribe.", required: true, positional: true)], forceable: true, timeout: 600),
    Command(name: "open", summary: "Open a document in the Talk & Read reader.", example: "open ~/Documents/notes.pdf --show 1 --read 1",
            params: [Param(name: "path", kind: .path, help: "Document to open.", required: true, positional: true),
                     Param(name: "show", kind: .string, help: "1 brings the main window forward; default 0 (no focus change).", choices: ["0", "1"]),
                     Param(name: "read", kind: .string, help: "1 also starts reading it aloud; default 0.", choices: ["0", "1"])], forceable: true),
    Command(name: "open-url", summary: "Open a web page in the reader, as the Library's Open web page… does: the page is fetched once and only its text is kept in the Library.",
            example: "open-url https://example.com/article --read 1",
            params: [Param(name: "url", kind: .string, help: "http or https address; a bare host such as example.com/page gets https.", required: true, positional: true),
                     Param(name: "show", kind: .string, help: "1 brings the main window forward; default 0 (no focus change).", choices: ["0", "1"]),
                     Param(name: "read", kind: .string, help: "1 also starts reading it aloud; default 0.", choices: ["0", "1"])], forceable: true, timeout: 60),
    Command(name: "read-pasted", summary: "Read text aloud as Home's paste and listen does: unlike speak, the text is also kept in the Library and in the History, and shown in the reader. Use - to read the text from standard input.",
            example: "read-pasted \"Notes for Monday\" --title Monday",
            params: [Param(name: "text", kind: .string, help: "Text to read.", required: true, positional: true, variadic: true),
                     Param(name: "title", kind: .string, help: "Library title; default the first line."),
                     Param(name: "show", kind: .string, help: "1 brings the main window forward; default 0 (no focus change).", choices: ["0", "1"])], forceable: true),
    Command(name: "library", summary: "List the documents in the Library, newest first: id, title, kind (pdf, web, pasted…), date added, saved reading position (a word number) and whether it is being read.",
            example: "library"),
    Command(name: "library-open", summary: "Show a Library document in the reader; with --read 1 also read it from the saved position, the start or a word number. Replies with its word count.",
            example: "library-open 0F8E2C1A-4B7D-4E3A-9C55-1D2E3F4A5B6C --read 1 --from start",
            params: [Param(name: "id", kind: .string, help: "Document id from `talkread library`.", required: true, positional: true),
                     Param(name: "show", kind: .string, help: "1 brings the main window forward; default 0 (no focus change).", choices: ["0", "1"]),
                     Param(name: "read", kind: .string, help: "1 also starts reading it aloud; default 0.", choices: ["0", "1"]),
                     Param(name: "from", kind: .string, help: "With --read 1: saved (default), start, or a word number from 0.")], forceable: true),
    Command(name: "library-remove", summary: "Remove a document from the Library for good, as Remove from Library does: its entry, its saved copy of the file and its text. The original file is not touched. Needs --yes.",
            example: "library-remove 0F8E2C1A-4B7D-4E3A-9C55-1D2E3F4A5B6C --yes",
            params: [Param(name: "id", kind: .string, help: "Document id from `talkread library`.", required: true, positional: true)],
            forceable: true, confirm: true),
    Command(name: "settings-get", summary: "Read one setting, or all of them.", example: "settings-get speed",
            params: [Param(name: "key", kind: .string, help: "Setting name, for example speed, voiceID, frenchVoiceID, fallbackVoiceID or readShortcut. Shortcuts come back as JSON (keyCode, modifiers, display).", positional: true)]),
    Command(name: "settings-set", summary: "Change a setting.", example: "settings-set speed 1.25",
            params: [Param(name: "key", kind: .string, help: "Setting name. voiceID takes an English voice, frenchVoiceID a French one, fallbackVoiceID an English Kokoro voice (used when a slower model falls behind). The ...Shortcut keys take ctrl, option, shift and cmd joined with + and one key (ctrl+option+R, cmd+shift+F5), or off; dictationHoldKey takes rightOption, fn, rightCommand or off.", required: true, positional: true),
                     Param(name: "value", kind: .string, help: "New value.", required: true, positional: true)], forceable: true),
    Command(name: "shortcuts-reset", summary: "Put every shortcut and the hold to dictate key back to the defaults, as Settings ▸ Shortcuts ▸ Reset does. Your own shortcuts are lost. Needs --yes.",
            example: "shortcuts-reset --yes", confirm: true),
    Command(name: "vocabulary", summary: "List the dictation vocabulary (what the recogniser hears and what to type instead) and the suggestions learnt from your corrections.",
            example: "vocabulary"),
    Command(name: "vocabulary-set", summary: "Add or change a vocabulary row: when dictation hears this, type that instead. The same word on both sides teaches its spelling.",
            example: "vocabulary-set \"marlow key\" Marlowe Quay",
            params: [Param(name: "heard", kind: .string, help: "What the recogniser hears.", required: true, positional: true),
                     Param(name: "typed", kind: .string, help: "What to type instead.", required: true, positional: true, variadic: true)]),
    Command(name: "vocabulary-remove", summary: "Remove a vocabulary row for good. Needs --yes.",
            example: "vocabulary-remove marlow key --yes",
            params: [Param(name: "heard", kind: .string, help: "The row's heard side, ignoring case.", required: true, positional: true, variadic: true)], confirm: true),
    Command(name: "vocabulary-suggestion", summary: "Accept (add to the vocabulary) or dismiss a suggestion from your corrections, as listed by `talkread vocabulary`.",
            example: "vocabulary-suggestion accept --heard okafor --typed Okafor",
            params: [Param(name: "action", kind: .string, help: "accept or dismiss.", required: true, positional: true, choices: ["accept", "dismiss"]),
                     Param(name: "heard", kind: .string, help: "The suggestion's heard side, exactly as listed.", required: true),
                     Param(name: "typed", kind: .string, help: "The suggestion's typed side, exactly as listed.", required: true)]),
    Command(name: "pronunciations", summary: "List the pronunciations: words the voice should say differently (the text on screen stays as written).",
            example: "pronunciations"),
    Command(name: "pronunciation-set", summary: "Add or change a pronunciation, used from the next read.",
            example: "pronunciation-set Nguyen win",
            params: [Param(name: "word", kind: .string, help: "The word as written.", required: true, positional: true),
                     Param(name: "say", kind: .string, help: "How to say it.", required: true, positional: true, variadic: true)]),
    Command(name: "pronunciation-remove", summary: "Remove a pronunciation for good. Needs --yes.",
            example: "pronunciation-remove Nguyen --yes",
            params: [Param(name: "word", kind: .string, help: "The word, ignoring case.", required: true, positional: true, variadic: true)], confirm: true),
    Command(name: "models", summary: "Show speech model status, or download models: without --model the Kokoro voice and dictation models (about 1 GB, waits until done); with --model one optional download (starts it and returns; status shows progress). The Breeze voices download only from the app, beside their licence.", example: "models download --model qwen",
            params: [Param(name: "action", kind: .string, help: "status or download; default status.", positional: true,
                           choices: ["status", "download"], defaultValue: "status"),
                     Param(name: "model", kind: .string, help: "With download: qwen (Qwen3 voices), word-timing (needed by Qwen3) or french (Kokoro's French voice).",
                           choices: ["qwen", "word-timing", "french"])]),
    Command(name: "update-check", summary: "Check for a newer Talk & Read now, as the menu's Check for Updates… does. Replies with a checkID; `status` then shows the result under updates (upToDate, available <version> or error). Sparkle's window asks the user before anything installs.",
            example: "update-check")
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
        let english = data["english"]?.stringValue, french = data["french"]?.stringValue
        for v in voices {
            guard let o = v.objectValue, let id = o["id"]?.stringValue else { continue }
            let rest = ["name", "accent", "gender", "model", "language"].compactMap { o[$0]?.stringValue }
            let installed = o["installed"]?.boolValue == false ? " (not installed)" : ""
            let current = id == english ? "  <- English voice" : id == french ? "  <- French voice" : ""
            print(([id] + rest).joined(separator: "  ") + installed + current)
        }
        return
    }
    if command == "history", let entries = data["entries"]?.arrayValue {
        for e in entries {
            guard let o = e.objectValue else { continue }
            let text = (o["text"]?.stringValue ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            print([o["date"]?.stringValue, o["kind"]?.stringValue, o["app"]?.stringValue, o["id"]?.stringValue].compactMap { $0 }.joined(separator: "  ")
                  + "  " + (text.count > 100 ? String(text.prefix(100)) + "…" : text))
        }
        if entries.isEmpty { print("No matching history.") }
        if data["truncated"]?.boolValue == true { stderrLine("The reply was cut short: use a smaller --limit or a --search.") }
        return
    }
    if command == "library", let items = data["items"]?.arrayValue {
        for v in items {
            guard let o = v.objectValue, let id = o["id"]?.stringValue else { continue }
            print([id, o["kind"]?.stringValue, o["title"]?.stringValue].compactMap { $0 }.joined(separator: "  ")
                  + (o["reading"]?.boolValue == true ? "  <- reading" : ""))
        }
        if items.isEmpty { print("The Library is empty.") }
        return
    }
    if command == "vocabulary" || command == "pronunciations", let entries = data["entries"]?.arrayValue {
        let (key, value) = command == "vocabulary" ? ("heard", "typed") : ("word", "say")
        func row(_ v: JSONValue, _ k: String, _ w: String) -> String { "\(v.objectValue?[k]?.stringValue ?? "")  ->  \(v.objectValue?[w]?.stringValue ?? "")" }
        for e in entries { print(row(e, key, value)) }
        if entries.isEmpty { print(command == "vocabulary" ? "No vocabulary yet." : "No pronunciations yet.") }
        let suggestions = data["suggestions"]?.arrayValue ?? []
        if !suggestions.isEmpty {
            print("Suggestions from your corrections (talkread vocabulary-suggestion accept|dismiss --heard … --typed …):")
            for e in suggestions { print("  " + row(e, "heard", "typed")) }
        }
        return
    }
    if command == "mic", let inputs = data["inputs"]?.arrayValue {
        let choice = data["choice"]?.stringValue ?? "default"
        print("default  System default" + (choice == "default" ? "  <- chosen" : ""))
        for v in inputs {
            guard let o = v.objectValue, let uid = o["uid"]?.stringValue else { continue }
            print("\(uid)  \(o["name"]?.stringValue ?? "")" + (o["default"]?.boolValue == true ? "  (system default)" : "")
                  + (o["chosen"]?.boolValue == true ? "  <- chosen" : ""))
        }
        if let using = data["using"]?.stringValue { print("Recording will use: \(using)") }
        if let notice = data["notice"]?.stringValue { print(notice) }
        return
    }
    print(response.message ?? "ok")
    if !data.isEmpty { print(data.sorted { $0.key < $1.key }.map { "\($0.key)=\(scalar($0.value))" }.joined(separator: " ")) }
}

func help(_ command: Command? = nil) {
    guard let command else {
        print("talkread <command> [options]   Control Talk & Read from the shell. A closed Talk & Read starts in the background, with no window; status never starts it.")
        for c in commands { print("  \(c.name.padding(toLength: 21, withPad: " ", startingAt: 0)) \(c.summary)") }
        print("Global options: --json  --force  --yes  --caller <name>  --request-id <uuid>  --timeout <seconds>  --help")
        print("Exit codes: 0 ok, 1 the app refused or failed, 2 usage, 3 Talk & Read is not running and could not be started.")
        print("Run `talkread <command> --help` for one command with an example.")
        return
    }
    let positional = command.params.filter(\.positional).map { p in
        let label = p.variadic ? "\(p.name)…" : p.name
        return p.required ? "<\(label)>" : "[\(label)]"
    }
    let flags = command.params.filter { !$0.positional }.map { $0.required ? "--\($0.name) <\($0.name)>" : "[--\($0.name) <\($0.name)>]" }
    print((["talkread", command.name] + positional + flags).joined(separator: " ") + (command.confirm ? " --yes" : "") + " [--json]"
          + (command.forceable ? " [--force]" : ""))
    print(command.summary)
    for p in command.params {
        print("  \(p.positional ? p.name : "--" + p.name)\(p.required ? " (required)" : ""): \(p.help)\(p.choices.map { " One of: " + $0.joined(separator: ", ") + "." } ?? "")")
    }
    if command.confirm { print("  --yes (required): confirms the removal. Without it nothing changes.") }
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
        if c.confirm { properties["yes"] = ["type": "boolean", "description": "Must be true: confirms the removal, which cannot be undone."] }
        let required: [String] = c.params.filter(\.required).map(\.name) + (c.confirm ? ["yes"] : [])
        return ["name": c.name.replacingOccurrences(of: "-", with: "_"), "description": c.summary,
                "inputSchema": ["type": "object", "properties": properties, "required": required,
                                "additionalProperties": false] as [String: Any]]
    }
    print(String(decoding: try! JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]), as: UTF8.self))
}

// MARK: Parse

let argv = Array(CommandLine.arguments.dropFirst())
func isNegativeNumber(_ s: String) -> Bool { s.hasPrefix("-") && s.count > 1 && Double(s) != nil }

json = argv.contains("--json")   // so usage errors are JSON even when --json comes after the mistake
var force = false, wantHelp = false, yes = false
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
    case "yes":
        // A plain switch; the MCP adapter sends --yes=true (and false when the agent did not confirm).
        switch parts.count == 2 ? parts[1].lowercased() : "true" {
        case "true", "1": yes = true
        case "false", "0": yes = false
        default: usage("--yes takes no value.", nil)
        }
        continue
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
if yes && !command.confirm { usage("\(command.name) does not take --yes.", command) }
if command.confirm && !yes { usage("\(command.name) removes something for good: add --yes to confirm.", command) }

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

if command.confirm { args["yes"] = "1" }

// MARK: Run

let longRunning = command.name == "models" && args["action"] == "download" && args["model"] == nil
let request = ControlRequest(id: requestID ?? UUID().uuidString, command: command.name, args: args,
                             caller: caller ?? "cli-\(getppid())", force: force)
let timeout = timeoutOverride ?? (longRunning ? 600 : command.timeout)

/// Starts a closed Talk & Read in the background (no window, no focus) and sends the request once its socket answers.
/// Only `app_not_running` is retried, and that error means nothing was sent, so no command can run twice.
func launchAndSend() throws -> ControlResponse {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // This helper's own app when it sits in Contents/Helpers, so a build never drives an older installed copy.
    launch.arguments = ["-g", "-j"] + (app.pathExtension == "app" ? ["-a", app.path] : ["-b", "com.juniornkanabassi.TalkAndRead"]) + ["--args", "--headless"]
    launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
    try launch.run(); launch.waitUntilExit()
    guard launch.terminationStatus == 0 else { throw ControlError("app_not_running", "Talk & Read is not running and could not be started.") }
    // The socket opens once the voices are listed, usually within a second; checking often answers as soon as it does.
    let deadline = Date().addingTimeInterval(20)
    while true {
        do { return try ControlClient.send(request, to: Paths.controlSocket, timeout: timeout) }
        catch let error as ControlError where error.code == "app_not_running" && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
}

do {
    let response: ControlResponse
    do { response = try ControlClient.send(request, to: Paths.controlSocket, timeout: timeout) }
    // status reports a closed app without starting it; a TALKREAD_HOME test root never starts the real app.
    catch let error as ControlError where error.code == "app_not_running" && command.name != "status"
        && ProcessInfo.processInfo.environment["TALKREAD_HOME"] == nil {
        response = try launchAndSend()
    }
    if json { printJSON(response) }
    else if response.ok { render(response, command: command.name) }
    else { stderrLine("\(response.code ?? "error"): \(response.message ?? "The request failed.")") }
    exit(response.ok ? 0 : 1)
} catch let error as ControlError {
    fail(error.code, error.message, exit: error.code == "app_not_running" ? 3 : 1)
} catch {
    fail("failed", error.localizedDescription, exit: 1)
}
