// A frozen main thread restarts the app (work Mac, 7 Nov 2026). An Objective-C exception that AppKit swallows in the
// middle of a SwiftUI update leaves SwiftUI's lock held, and every later update then waits on it for ever: the menu bar
// item, hotkeys and the control socket all stop. A background thread asks the main thread to check in every 5 s; after
// 30 s of awake time with no answer it logs, starts a fresh copy once this process has gone, and exits.
import AppKit
import TalkReadCore

enum Watchdog {
    static let limit: TimeInterval = 30
    nonisolated(unsafe) private static var beat = ProcessInfo.processInfo.systemUptime   // uptime stops while the Mac sleeps
    private static let lock = NSLock()

    static func start() {
        let thread = Thread {
            while true {
                DispatchQueue.main.async { lock.withLock { beat = ProcessInfo.processInfo.systemUptime } }
                Thread.sleep(forTimeInterval: 5)
                let silent = ProcessInfo.processInfo.systemUptime - lock.withLock { beat }
                if silent > limit { restart(after: silent) }
            }
        }
        thread.name = "Talk & Read watchdog"
        thread.start()
    }

    private static func restart(after silent: TimeInterval) {
        Log.write("watchdog: main thread silent for \(Int(silent)) s; restarting")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this pid to end, else `open` would only bring the frozen copy forward.
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -g -a \"$0\" --args --headless",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        _exit(1)   // not exit(): atexit work may need the frozen main thread
    }
}
