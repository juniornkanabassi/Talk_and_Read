// TEMPORARY. Declarations WP4 and WP5 add, so WP7 builds against main before those merges. Delete each section as
// soon as its package is merged: the real declarations replace these unchanged. (HotkeyAction would silently shadow
// TalkReadCore's, so that one must go with the WP5 merge.)
import AppKit
import Foundation
import TalkReadCore

// MARK: WP4: TextCapture.capture(app:), ScreenshotCapture

extension TextCapture {
    @MainActor static func capture(app: NSRunningApplication?) async -> Capture? { await captureSelection() }
}

enum ScreenshotCapture {
    @MainActor static func capture() async -> String? { nil }
}

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
