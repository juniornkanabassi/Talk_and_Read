// Pure state machine for the dictation hold key and chord shortcuts (PLAN decision 8, ESSENTIALS "Dictation key").
import Foundation

public enum HotkeyAction: Equatable, Sendable {
    case startRecording, stopAndInsert, cancelRecording, toggleRecording, pasteLast, read, pause, screenshot
    case increaseSpeed, decreaseSpeed, skipBackward, skipForward

    /// Only means something during a read, so its key is taken only while one is playing or paused (S3).
    public var actsOnRead: Bool { [.increaseSpeed, .decreaseSpeed, .skipBackward, .skipForward].contains(self) }
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

/// Which key events the hotkey tap swallows, so the app underneath never sees them (S3): a key-down that matches a
/// shortcut, with its auto-repeats and its key-up. The speed and skip keys only while a read is playing or paused (they
/// type ∂ ß ∑ ´ otherwise), Esc only while dictation records. Modifier changes always pass (the hold key works as
/// before), and so does everything while the shortcut recorder listens. Pure: the tap thread owns one and asks it about
/// every key event, with a snapshot of the shortcuts and of what is running.
public struct KeyConsumer: Sendable {
    public struct Context: Equatable, Sendable {
        public var settings: Settings
        /// A read is playing or paused.
        public var reading: Bool
        /// Dictation is recording.
        public var recording: Bool
        /// The shortcut recorder is listening: everything passes.
        public var paused: Bool
        public init(settings: Settings = Settings(), reading: Bool = false, recording: Bool = false, paused: Bool = false) {
            self.settings = settings; self.reading = reading; self.recording = recording; self.paused = paused
        }
    }
    public enum Event: Sendable { case down, autoRepeat, up, flagsChanged }

    /// Key codes whose key-down was swallowed; their repeats and key-up go the same way.
    private(set) var swallowing: Set<UInt16> = []

    public init() {}

    /// True = swallow. `ours`: an event Talk and Read posted itself (the insertion ⌘V), which always passes.
    public mutating func swallow(_ event: Event, keyCode: UInt16, modifiers: UInt64, ours: Bool, in c: Context) -> Bool {
        guard !ours else { return false }
        switch event {
        case .flagsChanged: return false
        case .autoRepeat: return swallowing.contains(keyCode)
        case .up: return swallowing.remove(keyCode) != nil
        case .down:
            swallowing.remove(keyCode)                 // a fresh press decides afresh (heals a key-up the tap missed)
            guard !c.paused else { return false }
            let take = if let action = c.settings.action(keyCode: keyCode, modifiers: modifiers) {
                !action.actsOnRead || c.reading
            } else {
                keyCode == HotkeyState.escapeKeyCode && c.recording
            }
            if take { swallowing.insert(keyCode) }
            return take
        }
    }
}
