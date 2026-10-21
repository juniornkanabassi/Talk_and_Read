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

// MARK: WP5: HotkeyAction (TalkReadCore), Hotkeys API

enum HotkeyAction: Equatable { case startRecording, stopAndInsert, cancelRecording, toggleRecording, pasteLast, read, pause, screenshot }

extension Hotkeys {
    convenience init(onAction: @escaping (HotkeyAction) -> Void) { self.init() }
    func start(settings: Settings) {}
    func reload(_ settings: Settings) {}
}
