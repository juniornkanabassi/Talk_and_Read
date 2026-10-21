// Codable settings with defaults and validation. Owned by WP2 (add validation, tolerate missing keys on decode).
import Foundation

public struct Settings: Codable, Equatable, Sendable {
    // Shortcuts (ARCHITECTURE-ESSENTIALS "Defaults").
    public var readSelectionShortcut = "ctrl+opt+R"
    public var pauseResumeShortcut = "ctrl+opt+P"
    public var dictationKey = "rightOption"
    public var dictationToggleShortcut = "ctrl+opt+D"
    public var pasteLastShortcut = "ctrl+opt+V"
    // Reading.
    public var voice = "af_heart"
    public var speed = 1.0                      // 0.5...3.0, step 0.05
    public var highlightColour = "#FFD21F"
    public var sentenceTintOpacity = 0.35
    public var miniPlayerAutoHideSeconds = 3.0
    // Dictation.
    public var removeFillers = true
    public var polish = false
    public var vocabulary: [String: String] = [:]
    public var pronunciations: [String: String] = [:]
    // Models.
    public var modelIdleUnloadMinutes = 10

    public init() {}
}
