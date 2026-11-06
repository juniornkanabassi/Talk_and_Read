import AppKit

/// Menu structure is checked without starting the app delegate, opening windows or invoking actions.
enum MenuSelfTest {
    @MainActor static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let menu = AppDelegate.mainMenu()
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failed += 1 }
        }
        check(menu.items.map(\.title) == ["Talk & Read", "File", "Edit", "View", "Playback", "Dictation", "Window", "Help"], "native menu order")
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        for (title, key, modifiers) in [
            ("Open file…", "o", NSEvent.ModifierFlags.command),
            ("Open web page…", "l", [.command, .shift]),
            ("Faster", "=", .command), ("Slower", "-", .command),
            ("Settings…", ",", .command), ("Undo", "z", .command), ("Redo", "z", [.command, .shift])
        ] {
            check(items.contains { $0.title == title && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }, "\(title) shortcut")
        }
        for title in ["Play", "Hide sidebar", "Previous sentence", "Next sentence", "Zoom", "Bring all to front", "Talk & Read help"] {
            check(items.contains { $0.title == title && $0.action != nil }, "\(title) command")
        }
        check(NSApp.windowsMenu?.title == "Window" && NSApp.helpMenu?.title == "Help", "system Window and Help registration")
        let window = WindowState(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        check(!AppDelegate.windowIsOpen(window), "closed window does not retain Dock icon")
        window.minimised = true
        check(AppDelegate.windowIsOpen(window), "minimised window retains Dock icon and permission polling")
        window.minimised = false
        window.testVisible = true
        check(AppDelegate.windowIsOpen(window), "visible window retains Dock icon")
        let settingsDelegate = SettingsDelegate()
        window.delegate = settingsDelegate
        let appDelegate = AppDelegate()
        appDelegate.registerSettingsWindow(window)
        check(window.delegate === settingsDelegate, "Settings registration preserves SwiftUI window delegate")
        check(MiniPlayer.autoHideDelay(setting: 0.5, hasMessage: true) == 3, "error toast remains readable for three seconds")
        check(MiniPlayer.autoHideDelay(setting: 0, hasMessage: true) == 3, "error toast hides with ordinary auto-hide disabled")
        check(MiniPlayer.autoHideDelay(setting: 10, hasMessage: true) == 10, "error toast honours longer configured delay")
        check(MiniPlayer.autoHideDelay(setting: 0, hasMessage: false) == nil, "ordinary player honours never hide")
        let model = AppModel.shared
        model.settings.showMiniPlayer = false
        MiniPlayer.shared.attach(model)
        MiniPlayer.shared.flash("Review fixture error")
        check(MiniPlayer.shared.message == "Review fixture error" && MiniPlayer.shared.isVisible,
              "errors remain visible with mini player disabled")
        MiniPlayer.shared.hide()
        check(TalkReadMain.isDisposableHome("/private/tmp/talkread-review-home"), "headless check accepts disposable home")
        check(!TalkReadMain.isDisposableHome("/Users/review-fixture/Library/Application Support/Talk and Read") && !TalkReadMain.isDisposableHome("/private/tmp"),
              "headless check rejects real home and temporary root")
        print("menu self-test: \(failed == 0 ? "PASS" : "FAIL"), \(failed) failures")
        return failed == 0 ? 0 : 1
    }
}

@MainActor private final class WindowState: NSWindow {
    var testVisible = false
    var minimised = false
    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { minimised }
}

@MainActor private final class SettingsDelegate: NSObject, NSWindowDelegate {}
