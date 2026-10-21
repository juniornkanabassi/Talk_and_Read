// Entry point: menu bar (accessory) app with a status item and Quit, plus the headless --selftest-* switches. Minimal; WP7 wires the rest.
import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = Self.menuBarImage() {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "T&R"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Talk and Read", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// MenuBarIcon.png is 18 pt; the @2x file supplies the retina representation.
    private static func menuBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        if let url2x = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let data = try? Data(contentsOf: url2x), let rep = NSBitmapImageRep(data: data) {
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }
}

@main
enum TalkReadMain {
    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // Headless switches run, report and exit; they never show UI or register a login item.
        if let file = value(after: "--selftest-tts") { exitAfter { await SelfTest.tts(file: file) } }
        if let dir = value(after: "--selftest-asr") { exitAfter { await SelfTest.asr(directory: dir) } }
        if args.contains("--selftest-window") { exit(SelfTestWindow.run()) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func exitAfter(_ work: @escaping () async -> Int32) -> Never {
        Task { exit(await work()) }
        dispatchMain()
    }
}
