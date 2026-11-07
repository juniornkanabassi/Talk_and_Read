// A frozen main thread restarts the app (work Mac, 7 Nov 2026). An Objective-C exception that AppKit swallows in the
// middle of a SwiftUI update leaves SwiftUI's lock held, and every later update then waits on it for ever: the menu bar
// item, hotkeys and the control socket all stop. A background thread asks the main thread to check in every second;
// after 12 s of awake time with no answer it logs, saves a `sample` of the process to Diagnostics/, starts a fresh copy
// once this process has gone, and exits. On the way it logs every main-thread stall of 1 s or more, and the app's
// memory and the Mac's swap every 15 minutes, so a slow day can be read back from talkread.log.
import AppKit
import Darwin
import TalkReadCore

enum Watchdog {
    static let limit: TimeInterval = 12
    static let stallLog: TimeInterval = 1
    nonisolated(unsafe) private static var beat = ProcessInfo.processInfo.systemUptime   // uptime stops while the Mac sleeps
    private static let lock = NSLock()

    static func start() {
        let thread = Thread {
            var memoryAt: TimeInterval = 0
            while true {
                let asked = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    let now = ProcessInfo.processInfo.systemUptime
                    lock.withLock { beat = now }
                    if now - asked >= stallLog { Log.write("stall: main thread busy for \(String(format: "%.1f", now - asked)) s") }
                }
                Thread.sleep(forTimeInterval: 1)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lock.withLock({ beat }) > limit { restart(after: now - lock.withLock { beat }) }
                if now - memoryAt >= 900 { memoryAt = now; Log.write("memory: \(memory())") }
            }
        }
        thread.name = "Talk & Read watchdog"
        thread.start()
    }

    /// "app 412 MB, swap 4871 MB used of 6144, free pages 3 %".
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var free: Int32 = 0, freeSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &free, &freeSize, nil, 0)
        return "app \(ok ? Int(info.phys_footprint >> 20) : -1) MB, swap \(swap.xsu_used >> 20) MB used of \(swap.xsu_total >> 20), free memory \(free) %"
    }

    private static func restart(after silent: TimeInterval) {
        Log.write("watchdog: main thread silent for \(Int(silent)) s; restarting (\(memory()))")
        let folder = Paths.dataRoot.appendingPathComponent("Diagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "2", "-file", folder.appendingPathComponent("freeze-\(stamp).txt").path]
        if (try? sample.run()) != nil { sample.waitUntilExit() }   // the stacks say what the main thread was waiting on
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this pid to end, else `open` would only bring the frozen copy forward.
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -g -a \"$0\" --args --headless",
                              Bundle.main.bundlePath]
        try? relaunch.run()
        _exit(1)   // not exit(): atexit work may need the frozen main thread
    }
}
