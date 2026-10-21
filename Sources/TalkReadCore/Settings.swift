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
        static func ctrlOpt(_ keyCode: UInt16, _ letter: String) -> Shortcut {
            Shortcut(keyCode: keyCode, modifiers: (1 << 18) | (1 << 19), display: "⌃⌥" + letter)
        }
    }
    public enum HoldKey: String, Codable, Sendable, CaseIterable { case rightOption, fn, off }

    public var readShortcut = Shortcut.ctrlOpt(15, "R")
    public var pauseShortcut = Shortcut.ctrlOpt(35, "P")
    public var screenshotShortcut = Shortcut.ctrlOpt(1, "S")
    public var dictationToggleShortcut = Shortcut.ctrlOpt(2, "D")
    public var pasteLastShortcut = Shortcut.ctrlOpt(9, "V")
    public var dictationHoldKey = HoldKey.rightOption
    public var voiceID = "af_heart"
    public var speed: Float = 1.0                  // 0.5...3.0, step 0.05
    public var highlightHex = "#FFD21F"
    public var tintEnabled = true
    public var opacity = 0.85
    public var showMiniPlayer = true
    public var miniPlayerAutoHideSeconds = 3.0     // 0 = never
    public var miniPlayerOrigin: CGPoint?
    public var subtitlesExpanded = false
    public var useOCRFallback = true
    public var removeFillers = true
    public var polishWithAppleIntelligence = false
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
        get(.pasteLastShortcut, &pasteLastShortcut); get(.dictationHoldKey, &dictationHoldKey)
        get(.voiceID, &voiceID); get(.speed, &speed); get(.highlightHex, &highlightHex)
        get(.tintEnabled, &tintEnabled); get(.opacity, &opacity); get(.showMiniPlayer, &showMiniPlayer)
        get(.miniPlayerAutoHideSeconds, &miniPlayerAutoHideSeconds); get(.miniPlayerOrigin, &miniPlayerOrigin)
        get(.subtitlesExpanded, &subtitlesExpanded); get(.useOCRFallback, &useOCRFallback)
        get(.removeFillers, &removeFillers); get(.polishWithAppleIntelligence, &polishWithAppleIntelligence)
        get(.unloadAfterMinutes, &unloadAfterMinutes); get(.launchAtLogin, &launchAtLogin)
        get(.onboardingDone, &onboardingDone); get(.historyLimit, &historyLimit)
    }

    // MARK: Validation

    /// A copy with every value clamped into its legal range.
    public func validated() -> Settings {
        var s = self
        s.speed = min(3.0, max(0.5, ((speed.isFinite ? speed : 1.0) * 20).rounded() / 20)) // 0.05 steps
        s.opacity = opacity.isFinite ? min(1.0, max(0.1, opacity)) : 0.85
        s.miniPlayerAutoHideSeconds = miniPlayerAutoHideSeconds.isFinite ? min(60, max(0, miniPlayerAutoHideSeconds)) : 3
        s.unloadAfterMinutes = min(240, max(1, unloadAfterMinutes))
        s.historyLimit = min(5000, max(10, historyLimit))
        if voiceID.trimmingCharacters(in: .whitespaces).isEmpty { s.voiceID = "af_heart" }
        if highlightHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { s.highlightHex = "#FFD21F" }
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
    /// Settings window only (ponytail: no shortcut text parser; add one if an agent needs to rebind keys).
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
        case "voiceID": voiceID = raw
        case "speed": speed = Float(try number())
        case "highlightHex":
            guard raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ControlError("invalid_value", "highlightHex must look like #FFD21F.")
            }
            highlightHex = raw.uppercased()
        case "tintEnabled": tintEnabled = try bool()
        case "opacity": opacity = try number()
        case "showMiniPlayer": showMiniPlayer = try bool()
        case "miniPlayerAutoHideSeconds": miniPlayerAutoHideSeconds = try number()
        case "subtitlesExpanded": subtitlesExpanded = try bool()
        case "useOCRFallback": useOCRFallback = try bool()
        case "removeFillers": removeFillers = try bool()
        case "polishWithAppleIntelligence": polishWithAppleIntelligence = try bool()
        case "unloadAfterMinutes": unloadAfterMinutes = Int(try number())
        case "launchAtLogin": launchAtLogin = try bool()
        case "onboardingDone": onboardingDone = try bool()
        case "historyLimit": historyLimit = Int(try number())
        case "readShortcut", "pauseShortcut", "screenshotShortcut", "dictationToggleShortcut", "pasteLastShortcut", "miniPlayerOrigin":
            throw ControlError("read_only_setting", "\(key) can only be changed in the Settings window.")
        default:
            throw ControlError("unknown_setting", "Unknown setting '\(key)'. Keys: \(Settings.keys.joined(separator: ", ")).")
        }
        self = validated()
    }
}
