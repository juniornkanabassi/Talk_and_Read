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
        print("menu self-test: \(failed == 0 ? "PASS" : "FAIL"), \(failed) failures")
        return failed == 0 ? 0 : 1
    }
}
