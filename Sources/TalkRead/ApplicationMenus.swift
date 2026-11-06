import AppKit
import SwiftUI

extension AppDelegate {
    static func mainMenu(delegate: AppDelegate? = nil) -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            return item
        }
        func command(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            item(title, action, key, mods, target: delegate)
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        var appItems = [item("About Talk & Read", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))]
        if Updates.shared.isEnabled {
            appItems.append(item("Check for updates…", #selector(Updates.checkForUpdates(_:)), target: Updates.shared))
        }
        appItems += [.separator(), command("Settings…", #selector(openSettings(_:)), ","), .separator()]
        let services = NSMenu(title: "Services")
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        NSApp.servicesMenu = services
        appItems += [serviceItem, .separator(), item("Hide Talk & Read", #selector(NSApplication.hide(_:)), "h"),
                     item("Hide others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                     item("Show all", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                     item("Quit Talk & Read", #selector(NSApplication.terminate(_:)), "q")]
        _ = add("Talk & Read", appItems)
        _ = add("File", [command("Open file…", #selector(openFile(_:)), "o"),
                         command("Open web page…", #selector(openWebPage(_:)), "l", [.command, .shift]), .separator(),
                         item("Close", #selector(NSWindow.performClose(_:)), "w")])
        _ = add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                         item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                         item("Paste", #selector(NSText.paste(_:)), "v"), item("Select all", #selector(NSText.selectAll(_:)), "a")])
        _ = add("View", [command("Hide sidebar", #selector(toggleSidebar(_:)), "s", [.command, .control]), .separator(),
                         command("Home", #selector(showHome(_:)), "1"), command("Library", #selector(showLibrary(_:)), "2"),
                         command("Dictation", #selector(showDictation(_:)), "3"), command("Voices…", #selector(showVoices(_:))),
                         item("Enter full screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        _ = add("Playback", [command("Play", #selector(playPause(_:))),
                             command("Stop", #selector(stopPlayback(_:))), .separator(),
                             command("Previous sentence", #selector(previousSentence(_:)), "["),
                             command("Next sentence", #selector(nextSentence(_:)), "]"), .separator(),
                             command("Faster", #selector(faster(_:)), "="), command("Slower", #selector(slower(_:)), "-"), .separator(),
                             command("Read selection", #selector(readSelection(_:))), command("Read from here", #selector(readFromHere(_:))),
                             command("Screenshot and listen", #selector(readScreenshot(_:)))])
        _ = add("Dictation", [command("Start dictation", #selector(toggleDictation(_:))),
                              command("Paste last transcript", #selector(pasteTranscript(_:)))])
        let windows = add("Window", [item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"),
                                     item("Zoom", #selector(NSWindow.performZoom(_:))), .separator(),
                                     item("Bring all to front", #selector(NSApplication.arrangeInFront(_:)))])
        NSApp.windowsMenu = windows
        let help = add("Help", [command("Talk & Read help", #selector(showHelp(_:)))])
        NSApp.helpMenu = help
        return main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let model = AppModel.shared
        let session = model.liveSession
        switch menuItem.action {
        case #selector(playPause(_:)):
            menuItem.title = model.pendingDocumentPaused.map { $0 ? "Resume" : "Pause" }
                ?? (session?.state == .playing ? "Pause" : session?.state == .paused ? "Resume" : "Play")
            return model.pendingDocumentPaused != nil || session != nil || !WindowRouter.shared.libraryPath.isEmpty
        case #selector(stopPlayback(_:)):
            return model.pendingDocumentPaused != nil || session != nil
        case #selector(previousSentence(_:)), #selector(nextSentence(_:)):
            return session != nil
        case #selector(faster(_:)): return model.activeSpeed < 4
        case #selector(slower(_:)): return model.activeSpeed > 0.5
        case #selector(toggleSidebar(_:)):
            menuItem.title = WindowRouter.shared.sidebarVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar"
            return true
        case #selector(toggleDictation(_:)):
            if case .recording = model.dictation.state { menuItem.title = "Stop dictation" }
            else { menuItem.title = "Start dictation" }
            return true
        case #selector(pasteTranscript(_:)): return !model.dictation.history.isEmpty
        default: return true
        }
    }

    @objc func openFile(_ sender: Any?) { WindowRouter.shared.chooseFiles(into: .shared) }
    @objc func openWebPage(_ sender: Any?) { WindowRouter.shared.openWebPage() }
    @objc func showHome(_ sender: Any?) { WindowRouter.shared.show(.home) }
    @objc func showLibrary(_ sender: Any?) { WindowRouter.shared.show(.library) }
    @objc func showDictation(_ sender: Any?) { WindowRouter.shared.show(.dictation) }
    @objc func showVoices(_ sender: Any?) { WindowRouter.shared.openSettings(.voices) }
    @objc func toggleSidebar(_ sender: Any?) {
        let router = WindowRouter.shared
        router.showMainWindow()
        router.sidebarVisibility = router.sidebarVisibility == .detailOnly ? .all : .detailOnly
    }
    @objc func playPause(_ sender: Any?) {
        let model = AppModel.shared
        if model.liveSession == nil, model.pendingDocumentPaused == nil,
           let item = WindowRouter.shared.libraryPath.last { model.read(item, fromToken: nil) }
        else { model.togglePause() }
    }
    @objc func stopPlayback(_ sender: Any?) { AppModel.shared.stopReading() }
    @objc func previousSentence(_ sender: Any?) { AppModel.shared.skip(-1) }
    @objc func nextSentence(_ sender: Any?) { AppModel.shared.skip(1) }
    @objc func faster(_ sender: Any?) { AppModel.shared.stepSpeed(up: true) }
    @objc func slower(_ sender: Any?) { AppModel.shared.stepSpeed(up: false) }
    @objc func readSelection(_ sender: Any?) { AppModel.shared.readSelection() }
    @objc func readFromHere(_ sender: Any?) { AppModel.shared.readHere() }
    @objc func readScreenshot(_ sender: Any?) { AppModel.shared.readScreenshot() }
    @objc func toggleDictation(_ sender: Any?) {
        let dictation = AppModel.shared.dictation
        if case .recording = dictation.state { try? dictation.stop(insert: true, caller: "user") }
        else { try? dictation.start(caller: "user") }
    }
    @objc func pasteTranscript(_ sender: Any?) { AppModel.shared.dictation.pasteLast() }
    @objc func showHelp(_ sender: Any?) { WindowRouter.shared.openSettings(.shortcuts) }
}
