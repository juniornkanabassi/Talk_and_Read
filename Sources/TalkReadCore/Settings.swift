// Codable settings with defaults, tolerant decoding and validation. Owned by WP2.
import Foundation
import CoreGraphics

public struct Settings: Codable, Equatable, Sendable {
    /// `modifiers` is a `CGEventFlags` raw value: command 1<<20, option 1<<19, control 1<<18, shift 1<<17.
    public struct Shortcut: Codable, Equatable, Sendable {
        public var keyCode: UInt16
        public var modifiers: UInt64
        public var display: String
        public init(keyCode: UInt16, modifiers: UInt64, display: String) {
            self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
        }
        /// Turned off: never matches (keyCode 0 alone would be "a").
        public static let off = Shortcut(keyCode: 0, modifiers: 0, display: "")
        public var isOff: Bool { display.isEmpty || modifiers == 0 }

        public static let command: UInt64 = 1 << 20, option: UInt64 = 1 << 19, control: UInt64 = 1 << 18, shift: UInt64 = 1 << 17
        /// The four modifiers a shortcut is made of; everything else in an event's flags (caps lock, fn, device bits) is ignored.
        public static let modifierMask = command | option | control | shift
    }
    /// Left Option is not offered: it types characters (∂, ß…) in every app.
    public enum HoldKey: String, Codable, Sendable, CaseIterable { case rightOption, fn, rightCommand, off }

    // Junior's Speechify set (S1, 23 Oct).
    public var readShortcut = Shortcut(keyCode: 0, modifiers: Shortcut.control, display: "⌃A")
    public var pauseShortcut = Shortcut(keyCode: 12, modifiers: Shortcut.control | Shortcut.option, display: "⌃⌥Q")
    public var screenshotShortcut = Shortcut(keyCode: 7, modifiers: Shortcut.control | Shortcut.option | Shortcut.command, display: "⌃⌥⌘X")
    public var dictationToggleShortcut = Shortcut(keyCode: 50, modifiers: Shortcut.control, display: "⌃`")
    public var pasteLastShortcut = Shortcut(keyCode: 9, modifiers: Shortcut.control | Shortcut.command, display: "⌃⌘V")
    public var increaseSpeedShortcut = Shortcut(keyCode: 2, modifiers: Shortcut.option, display: "⌥D")
    public var decreaseSpeedShortcut = Shortcut(keyCode: 1, modifiers: Shortcut.option, display: "⌥S")
    public var skipBackwardShortcut = Shortcut(keyCode: 13, modifiers: Shortcut.option, display: "⌥W")
    public var skipForwardShortcut = Shortcut(keyCode: 14, modifiers: Shortcut.option, display: "⌥E")
    public var dictationHoldKey = HoldKey.rightOption
    /// CoreAudio UID of the microphone dictation records from; nil = the system default input (`Microphone`).
    public var dictationMicrophone: String?
    /// The English voice (and any text not detected as French). Ids carry the model: `af_heart` (Kokoro), `qwen.us_warm` (Qwen3).
    public var voiceID = "af_heart"
    /// The voice for text detected as French (PLAN 0.3.0 decision 2).
    public var frenchVoiceID = "ff_siwis"
    /// The English Kokoro voice a read switches to when a slower model falls behind (V3); French uses `ff_siwis`.
    public var fallbackVoiceID = "af_heart"
    public var speed: Float = 2.5                  // 0.5...3.0, step 0.05; Junior's Speechify speed
    /// ReadAlong's "Enabled": false reads aloud with no box or tint over the app (the reader still highlights).
    public var showHighlight = true
    public var highlightHex = "#FFD21F"
    /// "box" (default), "outline" or "underline" (H1).
    public var highlightStyle = "box"
    public var tintEnabled = true
    /// The sentence tint's own colour (ReadAlong's "Tint colour"); nil = the word colour.
    public var tintHex: String?
    public var opacity = 0.85
    public var showMiniPlayer = true
    public var miniPlayerAutoHideSeconds = 3.0     // 0 = never
    public var miniPlayerOrigin: CGPoint?
    public var subtitlesExpanded = false
    public var useOCRFallback = true
    /// Speechify's "skip citations": bracketed reference numbers ([12], [3–5]) and superscript footnote marks are not
    /// spoken; they stay on screen.
    public var skipCitations = true
    /// Speechify's "skip headers and footers": in the reader, a PDF's running headers, footers and page numbers are not spoken.
    public var skipHeadersAndFooters = true
    public var removeFillers = true
    /// Break a long dictation (60 words or more) into paragraphs at its pauses (PLAN 0.6.0).
    public var paragraphs = true
    public var polishWithAppleIntelligence = false
    /// "parakeet" (default) or "apple" (built in, no download).
    public var dictationEngine = "parakeet"
    /// Opt in: read the field for 15 s after dictating to learn corrections.
    public var learnCorrections = false
    /// Respell American spellings the British dictionary rejects.
    public var britishSpelling = true
    public var unloadAfterMinutes = 10
    public var launchAtLogin = true
    public var onboardingDone = false
    public var historyLimit = 200

    public init() {}

    /// Older files keep working when fields are added: a missing or wrongly typed key falls back to its default.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        get(.readShortcut, &readShortcut); get(.pauseShortcut, &pauseShortcut)
        get(.screenshotShortcut, &screenshotShortcut); get(.dictationToggleShortcut, &dictationToggleShortcut)
        get(.pasteLastShortcut, &pasteLastShortcut); get(.dictationHoldKey, &dictationHoldKey); get(.dictationMicrophone, &dictationMicrophone)
        get(.increaseSpeedShortcut, &increaseSpeedShortcut); get(.decreaseSpeedShortcut, &decreaseSpeedShortcut)
        get(.skipBackwardShortcut, &skipBackwardShortcut); get(.skipForwardShortcut, &skipForwardShortcut)
        get(.voiceID, &voiceID); get(.frenchVoiceID, &frenchVoiceID); get(.fallbackVoiceID, &fallbackVoiceID); get(.speed, &speed); get(.showHighlight, &showHighlight); get(.highlightHex, &highlightHex); get(.highlightStyle, &highlightStyle)
        get(.tintEnabled, &tintEnabled); get(.tintHex, &tintHex); get(.opacity, &opacity); get(.showMiniPlayer, &showMiniPlayer)
        get(.miniPlayerAutoHideSeconds, &miniPlayerAutoHideSeconds); get(.miniPlayerOrigin, &miniPlayerOrigin)
        get(.subtitlesExpanded, &subtitlesExpanded); get(.useOCRFallback, &useOCRFallback)
        get(.skipCitations, &skipCitations); get(.skipHeadersAndFooters, &skipHeadersAndFooters)
        get(.removeFillers, &removeFillers); get(.paragraphs, &paragraphs); get(.polishWithAppleIntelligence, &polishWithAppleIntelligence)
        get(.dictationEngine, &dictationEngine); get(.learnCorrections, &learnCorrections); get(.britishSpelling, &britishSpelling)
        get(.unloadAfterMinutes, &unloadAfterMinutes); get(.launchAtLogin, &launchAtLogin)
        get(.onboardingDone, &onboardingDone); get(.historyLimit, &historyLimit)
    }

    // MARK: Validation

    /// A copy with every value clamped into its legal range.
    public func validated() -> Settings {
        var s = self
        s.speed = min(3.0, max(0.5, ((speed.isFinite ? speed : 2.5) * 20).rounded() / 20)) // 0.05 steps
        s.opacity = opacity.isFinite ? min(1.0, max(0.1, opacity)) : 0.85
        s.miniPlayerAutoHideSeconds = miniPlayerAutoHideSeconds.isFinite ? min(60, max(0, miniPlayerAutoHideSeconds)) : 3
        s.unloadAfterMinutes = min(240, max(1, unloadAfterMinutes))
        s.historyLimit = min(5000, max(10, historyLimit))
        let d = Settings()
        if voiceID.trimmingCharacters(in: .whitespaces).isEmpty { s.voiceID = d.voiceID }
        if frenchVoiceID.trimmingCharacters(in: .whitespaces).isEmpty { s.frenchVoiceID = d.frenchVoiceID }
        if fallbackVoiceID.trimmingCharacters(in: .whitespaces).isEmpty { s.fallbackVoiceID = d.fallbackVoiceID }
        if highlightHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { s.highlightHex = "#FFD21F" }
        if !["box", "outline", "underline"].contains(highlightStyle) { s.highlightStyle = "box" }
        if let t = tintHex, t.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { s.tintHex = nil }
        if !["parakeet", "apple"].contains(dictationEngine) { s.dictationEngine = "parakeet" }
        if dictationMicrophone?.isEmpty == true { s.dictationMicrophone = nil }
        return s
    }

    // MARK: Files

    /// Missing file gives defaults; a corrupt one is renamed `<name>.bad` (replacing an older `.bad`) and gives defaults.
    public static func load(from url: URL = Paths.settings) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        do { return try JSONDecoder().decode(Settings.self, from: data).validated() } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return Settings()
        }
    }

    public func save(to url: URL = Paths.settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(validated()).write(to: url, options: .atomic)
    }

    // MARK: Key-based access (settings-get / settings-set)

    /// Every field name, in declaration order (includes unset optionals).
    public static var keys: [String] { Mirror(reflecting: Settings()).children.compactMap(\.label) }

    /// The whole settings object as JSON values (unset optionals are omitted).
    public func json() -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    /// Changes one setting from its text form, then clamps. Shortcuts and the mini player position are changed in the
    /// Settings window only (ponytail: no shortcut text parser; add one, checked by `refusal`, if an agent needs to rebind keys).
    public mutating func set(_ key: String, to raw: String) throws {
        func bool() throws -> Bool {
            switch raw.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: throw ControlError("invalid_value", "\(key) must be true or false.")
            }
        }
        func number() throws -> Double {
            guard let v = Double(raw), v.isFinite else { throw ControlError("invalid_value", "\(key) must be a number.") }
            return min(1e9, max(-1e9, v))
        }
        switch key {
        case "dictationHoldKey":
            guard let v = HoldKey(rawValue: raw) else {
                throw ControlError("invalid_value", "dictationHoldKey must be one of: \(HoldKey.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            dictationHoldKey = v
        case "dictationMicrophone": throw ControlError("read_only_setting", "dictationMicrophone is changed with `talkread mic`.")
        case "voiceID": voiceID = raw
        case "frenchVoiceID": frenchVoiceID = raw
        case "fallbackVoiceID": fallbackVoiceID = raw
        case "speed": speed = Float(try number())
        case "highlightHex":
            guard raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ControlError("invalid_value", "highlightHex must look like #FFD21F.")
            }
            highlightHex = raw.uppercased()
        case "highlightStyle":
            guard ["box", "outline", "underline"].contains(raw) else {
                throw ControlError("invalid_value", "highlightStyle must be one of: box, outline, underline.")
            }
            highlightStyle = raw
        case "showHighlight": showHighlight = try bool()
        case "tintEnabled": tintEnabled = try bool()
        case "tintHex":
            if ["same", ""].contains(raw.lowercased()) { tintHex = nil; break }
            guard raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ControlError("invalid_value", "tintHex must look like #FFD21F, or be same (the word colour).")
            }
            tintHex = raw.uppercased()
        case "opacity": opacity = try number()
        case "showMiniPlayer": showMiniPlayer = try bool()
        case "miniPlayerAutoHideSeconds": miniPlayerAutoHideSeconds = try number()
        case "subtitlesExpanded": subtitlesExpanded = try bool()
        case "useOCRFallback": useOCRFallback = try bool()
        case "skipCitations": skipCitations = try bool()
        case "skipHeadersAndFooters": skipHeadersAndFooters = try bool()
        case "removeFillers": removeFillers = try bool()
        case "paragraphs": paragraphs = try bool()
        case "polishWithAppleIntelligence": polishWithAppleIntelligence = try bool()
        case "dictationEngine":
            guard ["parakeet", "apple"].contains(raw) else {
                throw ControlError("invalid_value", "dictationEngine must be one of: parakeet, apple.")
            }
            dictationEngine = raw
        case "learnCorrections": learnCorrections = try bool()
        case "britishSpelling": britishSpelling = try bool()
        case "unloadAfterMinutes": unloadAfterMinutes = Int(try number())
        case "launchAtLogin": launchAtLogin = try bool()
        case "onboardingDone": onboardingDone = try bool()
        case "historyLimit": historyLimit = Int(try number())
        case _ where key == "miniPlayerOrigin" || Self.chords.contains(where: { $0.key == key }):
            throw ControlError("read_only_setting", "\(key) can only be changed in the Settings window.")
        default:
            throw ControlError("unknown_setting", "Unknown setting '\(key)'. Keys: \(Settings.keys.joined(separator: ", ")).")
        }
        self = validated()
    }

    // MARK: Shortcuts (S1, S2)

    /// Every chord shortcut with its settings key and action, in the order the Shortcuts page lists them. The hotkey
    /// tap, the page and settings-set all use this list.
    public static var chords: [(key: String, path: WritableKeyPath<Settings, Shortcut>, action: HotkeyAction)] {
        [("dictationToggleShortcut", \.dictationToggleShortcut, .toggleRecording), ("pasteLastShortcut", \.pasteLastShortcut, .pasteLast),
         ("readShortcut", \.readShortcut, .read), ("pauseShortcut", \.pauseShortcut, .pause),
         ("screenshotShortcut", \.screenshotShortcut, .screenshot), ("increaseSpeedShortcut", \.increaseSpeedShortcut, .increaseSpeed),
         ("decreaseSpeedShortcut", \.decreaseSpeedShortcut, .decreaseSpeed), ("skipBackwardShortcut", \.skipBackwardShortcut, .skipBackward),
         ("skipForwardShortcut", \.skipForwardShortcut, .skipForward)]
    }

    /// The action bound to exactly this key and these modifiers (only ⌘ ⌥ ⌃ ⇧ count); a turned-off shortcut never matches.
    public func action(keyCode: UInt16, modifiers: UInt64) -> HotkeyAction? {
        let mods = modifiers & Shortcut.modifierMask
        return Self.chords.first {
            let s = self[keyPath: $0.path]
            return !s.isOff && s.keyCode == keyCode && s.modifiers & Shortcut.modifierMask == mods
        }?.action
    }

    public enum Refusal: Equatable, Sendable {
        /// No ⌃, ⌥ or ⌘: the key would stop typing in every app.
        case needsModifier
        /// macOS (or every app) already uses it.
        case reserved
        /// Another shortcut has it; the settings key of that one.
        case taken(String)
    }

    /// macOS combinations a shortcut may not take over: quit, close, hide, minimise, app and window switching,
    /// Spotlight, input sources, force quit, lock screen and the screenshot keys.
    public static let reserved: [(keyCode: UInt16, modifiers: UInt64)] = {
        let c = Shortcut.command, o = Shortcut.option, ctl = Shortcut.control, sh = Shortcut.shift
        return [(12, c), (13, c), (4, c), (46, c), (48, c), (48, c | sh), (50, c), (49, c), (49, ctl), (49, c | o), (53, c | o),
                (12, c | ctl), (20, c | sh), (21, c | sh), (23, c | sh)]
    }()

    /// Why `s` cannot be the shortcut stored under `key`, or nil when it can. Turning a shortcut off is always allowed.
    public func refusal(_ s: Shortcut, for key: String) -> Refusal? {
        if s == .off { return nil }
        let mods = s.modifiers & Shortcut.modifierMask
        guard mods & (Shortcut.control | Shortcut.option | Shortcut.command) != 0 else { return .needsModifier }
        if Self.reserved.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == mods }) { return .reserved }
        if let other = Self.chords.first(where: { c in
            let o = self[keyPath: c.path]
            return c.key != key && !o.isOff && o.keyCode == s.keyCode && o.modifiers & Shortcut.modifierMask == mods
        }) { return .taken(other.key) }
        return nil
    }

    /// Every shortcut and the hold key back to the defaults.
    public mutating func resetShortcuts() {
        let d = Settings()
        for c in Self.chords { self[keyPath: c.path] = d[keyPath: c.path] }
        dictationHoldKey = d.dictationHoldKey
    }
}
