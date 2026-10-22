// Pure state machine for the dictation hold key and chord shortcuts (PLAN decision 8, ESSENTIALS "Dictation key").
import Foundation

public enum HotkeyAction: Equatable, Sendable {
    case startRecording, stopAndInsert, cancelRecording, toggleRecording, pasteLast, read, pause, screenshot
}

public enum KeyEvent: Equatable, Sendable {
    case holdKeyDown, holdKeyUp
    /// Any other key (or another modifier) going down. `modifiers` = CGEventFlags raw value.
    case otherKeyDown(keyCode: UInt16, modifiers: UInt64)
    /// A configured shortcut matched; the id is the action it stands for.
    case chord(HotkeyAction)
}

public struct HotkeyState: Equatable, Sendable {
    public static let holdDelay = 0.150
    public static let escapeKeyCode: UInt16 = 53

    enum Hold: Equatable { case up, pending(since: Double), recording, chorded }
    private(set) var hold: Hold = .up

    public init() {}

    public mutating func handle(_ e: KeyEvent, at time: Double) -> [HotkeyAction] {
        switch e {
        case .holdKeyDown:
            // A second key-down means the key-up was missed: reset, dropping any recording it left running.
            let healed: [HotkeyAction] = hold == .recording ? [.cancelRecording] : []
            hold = .pending(since: time)
            return healed
        case .holdKeyUp:
            defer { hold = .up }
            return hold == .recording ? [.stopAndInsert] : []
        case .otherKeyDown(let keyCode, _):
            let chorded = chord()
            // Esc cancels whatever is recording (hold, toggle or an agent's); the controller ignores it when idle.
            if keyCode == Self.escapeKeyCode, chorded.isEmpty { return [.cancelRecording] }
            return chorded
        case .chord(let action):
            return chord() + [action]
        }
    }

    /// Starts recording once the hold key has been down alone for `holdDelay`.
    public mutating func tick(at time: Double) -> [HotkeyAction] {
        guard case .pending(let since) = hold, time - since >= Self.holdDelay else { return [] }
        hold = .recording
        return [.startRecording]
    }

    /// Forgets the hold key (hotkeys paused for the shortcut recorder, or shortcuts reloaded): a recording it started is
    /// discarded first, because the release that would stop it is ignored or no longer recognised (Sol #19). A pending
    /// hold has started nothing and only needs forgetting (its tick then finds `.up`).
    public mutating func reset() -> [HotkeyAction] {
        defer { hold = .up }
        return hold == .recording ? [.cancelRecording] : []
    }

    /// Another key while the hold key is down: before the delay it never records, after it the recording is discarded.
    private mutating func chord() -> [HotkeyAction] {
        switch hold {
        case .pending: hold = .chorded; return []
        case .recording: hold = .chorded; return [.cancelRecording]
        case .up, .chorded: return []
        }
    }
}
