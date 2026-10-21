// TEMPORARY. Declarations WP5 adds, so WP7 builds against main before that merge. Delete this file when WP5 is merged
// (HotkeyAction here would silently shadow TalkReadCore's), except `delete(_:)` if WP5 has not added it yet.
import AppKit
import Foundation
import TalkReadCore

// MARK: WP5: HotkeyAction (TalkReadCore), Hotkeys API, DictationController.handle

enum HotkeyAction: Equatable { case startRecording, stopAndInsert, cancelRecording, toggleRecording, pasteLast, read, pause, screenshot }

extension Hotkeys {
    convenience init(settings: Settings, onAction: ((HotkeyAction) -> Void)? = nil) { self.init() }
    @discardableResult func start() -> Bool { false }
    var paused: Bool { get { false } set {} }
    func reload(_ settings: Settings) {}
}

extension DictationController {
    func handle(_ action: HotkeyAction) {}
    func delete(_ id: UUID) {}   // asked of WP5 (21 Oct): drop the entry from `history` and rewrite Paths.history
}
