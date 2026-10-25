import XCTest
@testable import TalkReadCore

final class SettingsTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("settings.json") }

    override func setUpWithError() throws { dir = try makeTestDir("set") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDefaults() {
        let s = Settings()
        XCTAssertEqual(s.readShortcut, Settings.Shortcut(keyCode: 0, modifiers: 1 << 18, display: "⌃A"))
        XCTAssertEqual(s.dictationHoldKey, .rightOption)
        XCTAssertEqual(s.voiceID, "af_heart")
        XCTAssertEqual(s.frenchVoiceID, "ff_siwis")
        XCTAssertEqual(s.fallbackVoiceID, "af_heart")
        XCTAssertEqual(s.speed, 2.5)
        XCTAssertEqual(s.highlightHex, "#FFD21F")
        XCTAssertEqual(s.opacity, 0.85)
        XCTAssertEqual(s.miniPlayerAutoHideSeconds, 3)
        XCTAssertNil(s.miniPlayerOrigin)
        XCTAssertEqual(s.unloadAfterMinutes, 10)
        XCTAssertEqual(s.historyLimit, 200)
        XCTAssertTrue(s.tintEnabled && s.showMiniPlayer && s.useOCRFallback && s.removeFillers && s.launchAtLogin)
        XCTAssertFalse(s.subtitlesExpanded || s.polishWithAppleIntelligence || s.onboardingDone)
        XCTAssertEqual(s, s.validated(), "defaults are already valid")
    }

    func testDictationSettings() throws {
        let d = Settings()
        XCTAssertEqual(d.dictationEngine, "parakeet")
        XCTAssertFalse(d.learnCorrections)
        XCTAssertTrue(d.britishSpelling)
        XCTAssertTrue(d.paragraphs)
        // An old file without the keys gets the defaults; an unknown engine is clamped.
        try Data(#"{"voiceID":"bf_emma"}"#.utf8).write(to: file)
        let old = Settings.load(from: file)
        XCTAssertEqual(old.dictationEngine, "parakeet"); XCTAssertFalse(old.learnCorrections); XCTAssertTrue(old.britishSpelling)
        try Data(#"{"dictationEngine":"whisper","learnCorrections":true,"britishSpelling":false}"#.utf8).write(to: file)
        let s = Settings.load(from: file)
        XCTAssertEqual(s.dictationEngine, "parakeet"); XCTAssertTrue(s.learnCorrections); XCTAssertFalse(s.britishSpelling)
        // settings-set
        var t = Settings()
        try t.set("dictationEngine", to: "apple"); XCTAssertEqual(t.dictationEngine, "apple")
        try t.set("learnCorrections", to: "on"); XCTAssertTrue(t.learnCorrections)
        try t.set("britishSpelling", to: "no"); XCTAssertFalse(t.britishSpelling)
        try t.set("paragraphs", to: "off"); XCTAssertFalse(t.paragraphs)
        XCTAssertThrowsError(try t.set("dictationEngine", to: "whisper"))
        XCTAssertEqual(t.dictationEngine, "apple", "a rejected engine changes nothing")
    }

    func testSaveAndLoadRoundTrip() throws {
        var s = Settings()
        s.voiceID = "bf_emma"; s.speed = 1.75; s.dictationHoldKey = .fn; s.miniPlayerOrigin = CGPoint(x: 120, y: 340)
        s.readShortcut = .init(keyCode: 3, modifiers: 1 << 20, display: "⌘F")
        try s.save(to: file)
        XCTAssertEqual(Settings.load(from: file), s)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["settings.json"], "atomic write leaves no temp file")
    }

    func testMissingFileGivesDefaults() {
        XCTAssertEqual(Settings.load(from: file), Settings())
    }

    func testOlderFileKeepsWorkingWhenFieldsAreAdded() throws {
        // Only two keys, one wrongly typed: the rest fall back to their defaults.
        try Data(#"{"voiceID":"bf_emma","speed":"fast","historyLimit":50,"someFutureKey":1}"#.utf8).write(to: file)
        let s = Settings.load(from: file)
        XCTAssertEqual(s.voiceID, "bf_emma")
        XCTAssertEqual(s.historyLimit, 50)
        XCTAssertEqual(s.speed, 2.5)
        var expected = Settings(); expected.voiceID = "bf_emma"; expected.historyLimit = 50
        XCTAssertEqual(s, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a readable file is not renamed")
    }

    func testVoiceIDsFor030() throws {
        // A 0.2 file (no French or fallback voice, a Qwen3 English voice) gets the defaults for the new keys.
        try Data(#"{"voiceID":"qwen.us_warm","speed":2.5}"#.utf8).write(to: file)
        var s = Settings.load(from: file)
        XCTAssertEqual([s.voiceID, s.frenchVoiceID, s.fallbackVoiceID], ["qwen.us_warm", "ff_siwis", "af_heart"])
        // Wrongly typed or blank values fall back too.
        try Data(#"{"frenchVoiceID":7,"fallbackVoiceID":"  "}"#.utf8).write(to: file)
        s = Settings.load(from: file)
        XCTAssertEqual([s.frenchVoiceID, s.fallbackVoiceID], ["ff_siwis", "af_heart"])
        try s.set("frenchVoiceID", to: "qwen.fr_warm")
        try s.set("fallbackVoiceID", to: "bf_emma")
        XCTAssertEqual([s.frenchVoiceID, s.fallbackVoiceID], ["qwen.fr_warm", "bf_emma"])
        try s.save(to: file)
        XCTAssertEqual(Settings.load(from: file), s)
        try s.set("frenchVoiceID", to: " ")
        XCTAssertEqual(s.frenchVoiceID, "ff_siwis", "blank means the default")
        XCTAssertEqual(Settings().json()["frenchVoiceID"], .string("ff_siwis"))
    }

    func testCorruptFileIsRenamedAndDefaultsReturned() throws {
        try Data("{not json".utf8).write(to: file)
        XCTAssertEqual(Settings.load(from: file), Settings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("bad"), encoding: .utf8), "{not json")
        // A second corrupt file replaces the older .bad.
        try Data("[]".utf8).write(to: file)
        _ = Settings.load(from: file)
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("bad"), encoding: .utf8), "[]")
    }

    func testValidatedClamps() {
        var s = Settings()
        s.speed = 9; XCTAssertEqual(s.validated().speed, 3.0)
        s.speed = 0.1; XCTAssertEqual(s.validated().speed, 0.5)
        s.speed = 1.234; XCTAssertEqual(s.validated().speed, 1.25)
        s.speed = .nan; XCTAssertEqual(s.validated().speed, 2.5)
        s = Settings(); s.opacity = 5; XCTAssertEqual(s.validated().opacity, 1.0)
        s.opacity = -1; XCTAssertEqual(s.validated().opacity, 0.1)
        s = Settings(); s.miniPlayerAutoHideSeconds = -4; XCTAssertEqual(s.validated().miniPlayerAutoHideSeconds, 0)
        s = Settings(); s.unloadAfterMinutes = 0; XCTAssertEqual(s.validated().unloadAfterMinutes, 1)
        s = Settings(); s.historyLimit = 1_000_000; XCTAssertEqual(s.validated().historyLimit, 5000)
        s = Settings(); s.highlightHex = "yellow"; s.voiceID = "  "
        XCTAssertEqual(s.validated().highlightHex, "#FFD21F")
        XCTAssertEqual(s.validated().voiceID, "af_heart")
    }

    func testSavedFileIsAlwaysValid() throws {
        var s = Settings(); s.speed = 50
        try s.save(to: file)
        XCTAssertEqual(Settings.load(from: file).speed, 3.0)
    }

    func testSetByKey() throws {
        var s = Settings()
        try s.set("speed", to: "1.5"); XCTAssertEqual(s.speed, 1.5)
        try s.set("speed", to: "99"); XCTAssertEqual(s.speed, 3.0)
        try s.set("voiceID", to: "bf_emma"); XCTAssertEqual(s.voiceID, "bf_emma")
        try s.set("showMiniPlayer", to: "off"); XCTAssertFalse(s.showMiniPlayer)
        try s.set("removeFillers", to: "TRUE"); XCTAssertTrue(s.removeFillers)
        try s.set("dictationHoldKey", to: "off"); XCTAssertEqual(s.dictationHoldKey, .off)
        try s.set("highlightHex", to: "#abcdef"); XCTAssertEqual(s.highlightHex, "#ABCDEF")
        try s.set("historyLimit", to: "1e30"); XCTAssertEqual(s.historyLimit, 5000)
        try s.set("showHighlight", to: "off"); XCTAssertFalse(s.showHighlight)
        try s.set("tintHex", to: "#ff66aa"); XCTAssertEqual(s.tintHex, "#FF66AA")
        try s.set("tintHex", to: "same"); XCTAssertNil(s.tintHex)
        try s.set("skipCitations", to: "off"); XCTAssertFalse(s.skipCitations)
        try s.set("skipHeadersAndFooters", to: "no"); XCTAssertFalse(s.skipHeadersAndFooters)
        func code(_ key: String, _ value: String) -> String? {
            var copy = Settings()
            do { try copy.set(key, to: value); return nil } catch { return (error as? ControlError)?.code }
        }
        XCTAssertEqual(code("nope", "1"), "unknown_setting")
        XCTAssertEqual(code("speed", "fast"), "invalid_value")
        XCTAssertEqual(code("speed", "nan"), "invalid_value")
        XCTAssertEqual(code("tintEnabled", "maybe"), "invalid_value")
        XCTAssertEqual(code("dictationHoldKey", "left"), "invalid_value")
        XCTAssertEqual(code("highlightHex", "red"), "invalid_value")
        XCTAssertEqual(code("tintHex", "pink"), "invalid_value")
        XCTAssertEqual(code("miniPlayerOrigin", "x"), "read_only_setting")
        XCTAssertEqual(code("dictationMicrophone", "x"), "read_only_setting")   // `talkread mic`
        for key in Settings.chords.map(\.key) { XCTAssertEqual(code(key, "x"), "invalid_value", key) }
        // Every setting is known to settings-set (none falls through to unknown_setting), so the CLI reaches them all.
        for key in Settings.keys { XCTAssertNotEqual(code(key, "\u{1}"), "unknown_setting", key) }
        try s.set("dictationHoldKey", to: "rightCommand"); XCTAssertEqual(s.dictationHoldKey, .rightCommand)
        var untouched = Settings()
        _ = try? untouched.set("speed", to: "fast")
        XCTAssertEqual(untouched, Settings(), "a rejected value changes nothing")
    }

    func testShortcutsBySettingsSet() throws {
        let ctrl = Settings.Shortcut.control, opt = Settings.Shortcut.option, cmd = Settings.Shortcut.command, shift = Settings.Shortcut.shift
        var s = Settings()
        try s.set("readShortcut", to: "ctrl+option+R")
        XCTAssertEqual(s.readShortcut, Settings.Shortcut(keyCode: 15, modifiers: ctrl | opt, display: "⌃⌥R"))
        try s.set("pauseShortcut", to: "⌘⇧F5")
        XCTAssertEqual(s.pauseShortcut, Settings.Shortcut(keyCode: 96, modifiers: cmd | shift, display: "⇧⌘F5"), "glyph order as the recorder writes it")
        try s.set("screenshotShortcut", to: " Ctrl+Alt+space ")
        XCTAssertEqual(s.screenshotShortcut, Settings.Shortcut(keyCode: 49, modifiers: ctrl | opt, display: "⌃⌥Space"))
        try s.set("skipForwardShortcut", to: "off")
        XCTAssertTrue(s.skipForwardShortcut.isOff)
        // Every default parses back to itself, so the table agrees with the recorder's key codes.
        let d = Settings()
        for c in Settings.chords {
            let shortcut = d[keyPath: c.path]
            XCTAssertEqual(Settings.Shortcut(text: shortcut.display), shortcut, c.key)
        }
        func message(_ key: String, _ value: String) -> String? {
            var copy = Settings()
            do { try copy.set(key, to: value); return nil } catch { return (error as? ControlError)?.message }
        }
        XCTAssertEqual(message("readShortcut", "shift+R"), "⇧R on its own would stop that key typing; add ctrl, option or command.")
        XCTAssertEqual(message("readShortcut", "cmd+Q"), "⌘Q belongs to macOS.")
        XCTAssertEqual(message("readShortcut", "option+D"), "⌥D is already used by increaseSpeedShortcut.")
        XCTAssertNotNil(message("readShortcut", "ctrl+banana"))
        XCTAssertNotNil(message("readShortcut", "ctrl+"))
        var untouched = Settings()
        _ = try? untouched.set("readShortcut", to: "cmd+Q")
        XCTAssertEqual(untouched, Settings(), "a refused shortcut changes nothing")
    }

    func testJSONAndKeys() {
        let json = Settings().json()
        XCTAssertEqual(json["voiceID"], .string("af_heart"))
        XCTAssertEqual(json["speed"], .number(2.5))
        XCTAssertEqual(json["dictationHoldKey"], .string("rightOption"))
        XCTAssertEqual(json["readShortcut"]?.objectValue?["display"], .string("⌃A"))
        XCTAssertEqual(json["skipForwardShortcut"]?.objectValue, ["keyCode": .number(14), "modifiers": .number(524_288), "display": .string("⌥E")])
        XCTAssertNil(json["miniPlayerOrigin"])
        XCTAssertEqual(Settings.keys.count, 38)   // + dictationMicrophone (0.5.0); + dictationEngine, learnCorrections, britishSpelling (V-G); + paragraphs (0.6.0); + showHighlight, tintHex, skipCitations, skipHeadersAndFooters
        XCTAssertNil(json["tintHex"], "the tint follows the word colour until one is chosen")
        XCTAssertEqual(json["skipCitations"], .bool(true))
        XCTAssertEqual(json["skipHeadersAndFooters"], .bool(true))
        XCTAssertEqual(Set(Settings.chords.map(\.key)).count, 9)
        XCTAssertTrue(Settings.chords.allSatisfy { Settings.keys.contains($0.key) }, "every chord is a settings key")
        XCTAssertTrue(Settings.keys.contains("miniPlayerOrigin"))
        var s = Settings(); s.speed = 1.15
        XCTAssertEqual(s.json()["speed"], .number(1.15))
    }

    func testPathsAndLog() throws {
        XCTAssertEqual(Paths.library.lastPathComponent, "library.json")
        XCTAssertEqual(Paths.documents.lastPathComponent, "Documents")
        XCTAssertEqual([Paths.history, Paths.reads, Paths.pronunciations, Paths.vocabulary, Paths.log].map(\.lastPathComponent),
                       ["dictation-history.json", "reads.json", "pronunciations.json", "vocabulary.json", "talkread.log"])
        XCTAssertEqual(Paths.controlSocket.deletingLastPathComponent().path, Paths.dataRoot.path)

        let log = dir.appendingPathComponent("talkread.log")
        Log.write("first", to: log)
        Log.write("second", to: log)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" first") && lines[0].contains("T"), String(lines[0]))
        // At 5 MB the file rotates to talkread.1.log.
        try Data(repeating: 120, count: Log.maxBytes).write(to: log)
        Log.write("after rotation", to: log)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("talkread.1.log")).count, Log.maxBytes)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix(" after rotation\n"))
        XCTAssertLessThan(try Data(contentsOf: log).count, 200)
    }

    func testShortcutDisplayRoundTrips() {
        for text in ["ctrl+left", "option+return", "cmd+shift+tab", "ctrl+up", "⌃⌥R", "ctrl+space"] {
            guard let s = Settings.Shortcut(text: text) else { return XCTFail(text) }
            XCTAssertEqual(Settings.Shortcut(text: s.display), s, text)
        }
    }
}
