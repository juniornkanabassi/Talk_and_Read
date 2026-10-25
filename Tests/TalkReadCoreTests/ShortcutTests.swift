import XCTest
@testable import TalkReadCore

/// S1–S4: the Speechify defaults, old settings files, refusals, reset, speed clamp, and which key events the active
/// hotkey tap swallows (every row of the S1 brief's requirement 2).
final class ShortcutTests: XCTestCase {
    private let ctrl = Settings.Shortcut.control, opt = Settings.Shortcut.option, cmd = Settings.Shortcut.command
    private let shift = Settings.Shortcut.shift

    func testDefaultsAreJuniorsSpeechifySet() {
        let s = Settings()
        let got = Settings.chords.map { s[keyPath: $0.path] }
        XCTAssertEqual(got.map(\.display), ["⌃`", "⌃⌘V", "⌃A", "⌃⌥Q", "⌃⌥⌘X", "⌥D", "⌥S", "⌥W", "⌥E"])
        XCTAssertEqual(got.map(\.keyCode), [50, 9, 0, 12, 7, 2, 1, 13, 14])
        XCTAssertEqual(got.map(\.modifiers), [ctrl, ctrl | cmd, ctrl, ctrl | opt, ctrl | opt | cmd, opt, opt, opt, opt])
        XCTAssertEqual(Settings.chords.map(\.action), [.toggleRecording, .pasteLast, .read, .pause, .screenshot,
                                                      .increaseSpeed, .decreaseSpeed, .skipBackward, .skipForward])
        XCTAssertEqual(s.dictationHoldKey, .rightOption)
        XCTAssertEqual(s.speed, 2.5)
        for c in Settings.chords { XCTAssertNil(s.refusal(s[keyPath: c.path], for: c.key), "default \(c.key) passes its own rules") }
    }

    func testOldSettingsFileGetsTheNewDefaults() throws {
        // A file written before S1: the five old shortcuts and speed 1.0, none of the four new keys.
        let old = #"""
        {"readShortcut":{"keyCode":15,"modifiers":786432,"display":"⌃⌥R"},"pauseShortcut":{"keyCode":35,"modifiers":786432,"display":"⌃⌥P"},
         "screenshotShortcut":{"keyCode":1,"modifiers":786432,"display":"⌃⌥S"},"dictationToggleShortcut":{"keyCode":2,"modifiers":786432,"display":"⌃⌥D"},
         "pasteLastShortcut":{"keyCode":9,"modifiers":786432,"display":"⌃⌥V"},"dictationHoldKey":"fn","speed":1.0,"voiceID":"bf_emma"}
        """#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.readShortcut.display, "⌃⌥R", "saved shortcuts are kept")
        XCTAssertEqual(s.dictationHoldKey, .fn)
        XCTAssertEqual(s.speed, 1.0, "a saved speed is kept")
        let d = Settings()
        XCTAssertEqual([s.increaseSpeedShortcut, s.decreaseSpeedShortcut, s.skipBackwardShortcut, s.skipForwardShortcut],
                       [d.increaseSpeedShortcut, d.decreaseSpeedShortcut, d.skipBackwardShortcut, d.skipForwardShortcut])
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(#"{"dictationHoldKey":"leftOption"}"#.utf8)).dictationHoldKey,
                       .rightOption, "an unknown hold key falls back")
    }

    func testRefusals() {
        let s = Settings()
        func sc(_ keyCode: UInt16, _ mods: UInt64) -> Settings.Shortcut { .init(keyCode: keyCode, modifiers: mods, display: "x") }
        XCTAssertEqual(s.refusal(sc(0, 0), for: "readShortcut"), .needsModifier, "plain A")
        XCTAssertEqual(s.refusal(sc(0, shift), for: "readShortcut"), .needsModifier, "⇧A still types")
        for (code, mods) in [(12, cmd), (13, cmd), (48, cmd), (49, cmd), (49, ctrl), (20, cmd | shift), (21, cmd | shift), (23, cmd | shift)] as [(UInt16, UInt64)] {
            XCTAssertEqual(s.refusal(sc(code, mods), for: "readShortcut"), .reserved, "\(code) \(mods)")
        }
        XCTAssertEqual(s.refusal(sc(0, ctrl), for: "increaseSpeedShortcut"), .taken("readShortcut"), "⌃A belongs to Start reading")
        XCTAssertEqual(s.refusal(sc(2, opt), for: "readShortcut"), .taken("increaseSpeedShortcut"))
        XCTAssertEqual(s.refusal(sc(0, ctrl | 0x100), for: "pauseShortcut"), .taken("readShortcut"), "only ⌘⌥⌃⇧ count")
        XCTAssertNil(s.refusal(sc(0, ctrl), for: "readShortcut"), "its own combination is no clash")
        XCTAssertNil(s.refusal(sc(15, ctrl | opt), for: "readShortcut"), "⌃⌥R is free")
        XCTAssertNil(s.refusal(.off, for: "readShortcut"), "turning off is always allowed")
        var off = s
        off.readShortcut = .off
        XCTAssertNil(off.refusal(sc(0, ctrl), for: "pauseShortcut"), "a turned-off shortcut holds nothing")
    }

    func testResetShortcutsKeepsEverythingElse() {
        var s = Settings()
        s.readShortcut = .init(keyCode: 15, modifiers: ctrl | opt, display: "⌃⌥R")
        s.skipForwardShortcut = .off
        s.dictationHoldKey = .off
        s.speed = 1.2
        s.voiceID = "bf_emma"
        s.resetShortcuts()
        var want = Settings()
        want.speed = 1.2
        want.voiceID = "bf_emma"
        XCTAssertEqual(s, want)
    }

    func testSpeedStepClamps() {
        var s = Settings()
        s.speed = 4.0 + 0.05; XCTAssertEqual(s.validated().speed, 4.0)
        s.speed = 0.5 - 0.05; XCTAssertEqual(s.validated().speed, 0.5)
        s.speed = 2.5 + 0.05; XCTAssertEqual(s.validated().speed, 2.55)
        s.speed = 2.5 - 0.05; XCTAssertEqual(s.validated().speed, 2.45)
    }

    func testActionMatching() {
        let s = Settings()
        XCTAssertEqual(s.action(keyCode: 0, modifiers: ctrl), .read)
        XCTAssertEqual(s.action(keyCode: 0, modifiers: ctrl | 0x10000 | 0x800000 | 0x1), .read, "caps lock, fn and device bits are ignored")
        XCTAssertNil(s.action(keyCode: 0, modifiers: ctrl | shift))
        XCTAssertNil(s.action(keyCode: 0, modifiers: 0))
        var off = s
        off.readShortcut = .off
        XCTAssertNil(off.action(keyCode: 0, modifiers: ctrl))
        XCTAssertNil(off.action(keyCode: 0, modifiers: 0), "off (keyCode 0) never matches plain A")
    }

    // MARK: KeyConsumer: what the active tap swallows

    private let reading = KeyConsumer.Context(reading: true)
    private let idle = KeyConsumer.Context()

    func testMatchedShortcutIsSwallowedWithItsRepeatsAndKeyUp() {
        var k = KeyConsumer()
        XCTAssertTrue(k.swallow(.down, keyCode: 0, modifiers: ctrl, ours: false, in: idle), "⌃A down")
        XCTAssertTrue(k.swallow(.autoRepeat, keyCode: 0, modifiers: ctrl, ours: false, in: idle), "its repeat")
        XCTAssertTrue(k.swallow(.autoRepeat, keyCode: 0, modifiers: 0, ours: false, in: idle), "its repeat after ⌃ is let go")
        XCTAssertTrue(k.swallow(.up, keyCode: 0, modifiers: 0, ours: false, in: idle), "its key-up")
        XCTAssertFalse(k.swallow(.up, keyCode: 0, modifiers: 0, ours: false, in: idle), "a second key-up passes")
        XCTAssertFalse(k.swallow(.down, keyCode: 0, modifiers: 0, ours: false, in: idle), "plain A types")
        XCTAssertFalse(k.swallow(.autoRepeat, keyCode: 0, modifiers: 0, ours: false, in: idle))
        XCTAssertFalse(k.swallow(.up, keyCode: 0, modifiers: 0, ours: false, in: idle))
        for (code, mods) in [(12, ctrl | opt), (7, ctrl | opt | cmd), (50, ctrl), (9, ctrl | cmd)] as [(UInt16, UInt64)] {
            XCTAssertTrue(k.swallow(.down, keyCode: code, modifiers: mods, ours: false, in: idle), "\(code) is always taken")
            XCTAssertTrue(k.swallow(.up, keyCode: code, modifiers: 0, ours: false, in: idle))
        }
    }

    func testResetForgetsSwallowedKeysAfterATapRestart() {
        var k = KeyConsumer()
        XCTAssertTrue(k.swallow(.down, keyCode: 0, modifiers: ctrl, ours: false, in: idle), "⌃A held")
        k.reset()   // the tap was disabled while it was held: its key-up was never seen
        XCTAssertFalse(k.swallow(.autoRepeat, keyCode: 0, modifiers: 0, ours: false, in: idle), "nothing is swallowed after the reset")
        XCTAssertFalse(k.swallow(.up, keyCode: 0, modifiers: 0, ours: false, in: idle), "a stale key-up passes")
        XCTAssertTrue(k.swallowing.isEmpty)
    }

    func testUnmatchedKeysPass() {
        var k = KeyConsumer()
        XCTAssertFalse(k.swallow(.down, keyCode: 0, modifiers: ctrl | shift, ours: false, in: reading), "⌃⇧A")
        XCTAssertFalse(k.swallow(.down, keyCode: 15, modifiers: ctrl | opt, ours: false, in: reading), "old ⌃⌥R")
        XCTAssertFalse(k.swallow(.down, keyCode: 8, modifiers: cmd, ours: false, in: reading), "⌘C")
        XCTAssertTrue(k.swallowing.isEmpty)
    }

    func testFlagsChangedNeverSwallowed() {
        var k = KeyConsumer()
        for (code, mods) in [(61, opt | 0x40), (61, 0), (59, ctrl), (63, 1 << 23), (54, cmd | 0x10)] as [(UInt16, UInt64)] {
            XCTAssertFalse(k.swallow(.flagsChanged, keyCode: code, modifiers: mods, ours: false,
                                     in: KeyConsumer.Context(reading: true, recording: true)), "\(code)")
        }
    }

    func testSpeedAndSkipKeysOnlyWhileReading() {
        for code: UInt16 in [2, 1, 13, 14] {                                  // ⌥D ⌥S ⌥W ⌥E
            var k = KeyConsumer()
            XCTAssertFalse(k.swallow(.down, keyCode: code, modifiers: opt, ours: false, in: idle), "\(code) types ∂ ß ∑ ´ when nothing is read")
            XCTAssertFalse(k.swallow(.autoRepeat, keyCode: code, modifiers: opt, ours: false, in: idle))
            XCTAssertFalse(k.swallow(.up, keyCode: code, modifiers: opt, ours: false, in: idle))
            XCTAssertTrue(k.swallow(.down, keyCode: code, modifiers: opt, ours: false, in: reading), "\(code) taken while playing or paused")
            XCTAssertTrue(k.swallow(.autoRepeat, keyCode: code, modifiers: opt, ours: false, in: reading))
            XCTAssertTrue(k.swallow(.up, keyCode: code, modifiers: opt, ours: false, in: idle), "the key-up follows its key-down even if the read ended")
        }
        // A rebound speed key is gated the same way: the action decides, not the letter.
        var s = Settings()
        s.increaseSpeedShortcut = .init(keyCode: 24, modifiers: ctrl | opt, display: "⌃⌥=")
        var k = KeyConsumer()
        XCTAssertFalse(k.swallow(.down, keyCode: 24, modifiers: ctrl | opt, ours: false, in: .init(settings: s)))
        XCTAssertTrue(k.swallow(.down, keyCode: 24, modifiers: ctrl | opt, ours: false, in: .init(settings: s, reading: true)))
        XCTAssertFalse(k.swallow(.down, keyCode: 2, modifiers: opt, ours: false, in: .init(settings: s, reading: true)), "old ⌥D is free again")
    }

    func testEscOnlyWhileRecording() {
        var k = KeyConsumer()
        XCTAssertFalse(k.swallow(.down, keyCode: 53, modifiers: 0, ours: false, in: reading), "Esc passes when not dictating")
        XCTAssertFalse(k.swallow(.up, keyCode: 53, modifiers: 0, ours: false, in: reading))
        let recording = KeyConsumer.Context(recording: true)
        XCTAssertTrue(k.swallow(.down, keyCode: 53, modifiers: 0, ours: false, in: recording))
        XCTAssertTrue(k.swallow(.autoRepeat, keyCode: 53, modifiers: 0, ours: false, in: recording))
        XCTAssertTrue(k.swallow(.up, keyCode: 53, modifiers: 0, ours: false, in: idle))
    }

    func testOurOwnPasteAlwaysPasses() {
        var k = KeyConsumer()
        var s = Settings()
        s.pasteLastShortcut = .init(keyCode: 9, modifiers: cmd, display: "⌘V")   // even if someone bound ⌘V
        let c = KeyConsumer.Context(settings: s, recording: true)
        XCTAssertFalse(k.swallow(.down, keyCode: 9, modifiers: cmd, ours: true, in: c))
        XCTAssertFalse(k.swallow(.up, keyCode: 9, modifiers: cmd, ours: true, in: c))
        XCTAssertTrue(k.swallow(.down, keyCode: 9, modifiers: cmd, ours: false, in: c), "the human's own ⌘V is the shortcut")
    }

    func testPausedPassesEverything() {
        var k = KeyConsumer()
        let paused = KeyConsumer.Context(reading: true, recording: true, paused: true)
        for (code, mods) in [(0, ctrl), (2, opt), (53, 0), (12, ctrl | opt)] as [(UInt16, UInt64)] {
            XCTAssertFalse(k.swallow(.down, keyCode: code, modifiers: mods, ours: false, in: paused), "\(code) reaches the recorder")
            XCTAssertFalse(k.swallow(.up, keyCode: code, modifiers: mods, ours: false, in: paused))
        }
        // A key swallowed before the pause keeps its key-up away from the app too.
        XCTAssertTrue(k.swallow(.down, keyCode: 0, modifiers: ctrl, ours: false, in: idle))
        XCTAssertTrue(k.swallow(.up, keyCode: 0, modifiers: 0, ours: false, in: paused))
    }

    func testTurnedOffShortcutPasses() {
        var s = Settings()
        s.readShortcut = .off
        var k = KeyConsumer()
        XCTAssertFalse(k.swallow(.down, keyCode: 0, modifiers: ctrl, ours: false, in: .init(settings: s)), "⌃A selects all again")
        XCTAssertFalse(k.swallow(.down, keyCode: 0, modifiers: 0, ours: false, in: .init(settings: s)), "plain A types")
    }

    func testMissedKeyUpHealsOnTheNextPress() {
        var k = KeyConsumer()
        XCTAssertTrue(k.swallow(.down, keyCode: 2, modifiers: opt, ours: false, in: reading))
        // Key-up lost (tap briefly disabled); the read ends; the next ⌥D must type normally, repeats and all.
        XCTAssertFalse(k.swallow(.down, keyCode: 2, modifiers: opt, ours: false, in: idle))
        XCTAssertFalse(k.swallow(.autoRepeat, keyCode: 2, modifiers: opt, ours: false, in: idle))
        XCTAssertFalse(k.swallow(.up, keyCode: 2, modifiers: opt, ours: false, in: idle))
    }
}
