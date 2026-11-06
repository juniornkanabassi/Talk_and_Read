// Compile with swiftc; usage: check-invisible evidence.json command [arguments...].
// Samples the command and its descendants every 0.2 seconds, without creating or activating an app.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: check-invisible evidence.json command [arguments...]") }
let destination = URL(fileURLWithPath: args[1])
let baseline = NSWorkspace.shared.frontmostApplication?.processIdentifier
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
child.arguments = Array(args.dropFirst(2))
var owned = Set<pid_t>()
var windows: [[String: Any]] = []
var focusChanges: [[String: Any]] = []
var ownFocus: [[String: Any]] = []
var samples = 0
var lastFront = baseline
var scanFailed = false

func sample() {
    // Keep PIDs after exit/reparenting so helper windows remain covered.
    let ps = Process(), pipe = Pipe()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,ppid="]
    ps.standardOutput = pipe
    do { try ps.run() } catch { scanFailed = true; return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    if ps.terminationStatus != 0 { scanFailed = true }
    let pairs = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (pid_t, pid_t)? in
        let numbers = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }
    var added = true
    while added {
        added = false
        for (pid, parent) in pairs where owned.contains(parent) && !owned.contains(pid) {
            owned.insert(pid); added = true
        }
    }
    guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        scanFailed = true; return
    }
    for entry in entries {
        let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
        if owned.contains(pid) && alpha > 0 {
            windows.append(["sample": samples, "pid": pid, "alpha": alpha,
                            "owner": entry[kCGWindowOwnerName as String] as? String ?? "unknown"])
        }
    }
    // Fails only when the command or a descendant is frontmost or active; other apps' changes are diagnostic.
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSWorkspace.shared.runningApplications.filter(\.isActive).map(\.processIdentifier)
    for pid in Set(active + [front].compactMap { $0 }) where owned.contains(pid) {
        ownFocus.append(["sample": samples, "pid": pid, "frontmost": pid == front, "active": active.contains(pid)])
    }
    if front != lastFront {
        focusChanges.append(["sample": samples, "from": lastFront ?? -1, "to": front ?? -1])
        lastFront = front
    }
    samples += 1
}

sample()
do { try child.run() } catch { fatalError("launch failed: \(error)") }
owned.insert(child.processIdentifier)
repeat {
    sample()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
} while child.isRunning
child.waitUntilExit()
sample()
let summary: [String: Any] = ["command": Array(args.dropFirst(2)), "exitCode": child.terminationStatus,
    "samples": samples, "intervalSeconds": 0.2, "trackedPIDs": owned.sorted(),
    "visibleWindows": windows, "frontmostChanges": focusChanges, "samplingFailed": scanFailed,
    "baselineFrontmostPID": baseline ?? -1,
    "ownFrontmostOrActive": ownFocus, "commandTookFocus": !ownFocus.isEmpty]
try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
print("Visibility proof: \(samples) samples, \(windows.count) visible windows, \(ownFocus.count) own frontmost/active samples, \(focusChanges.count) frontmost changes (diagnostic); child exit \(child.terminationStatus)")
exit(windows.isEmpty && ownFocus.isEmpty && !scanFailed ? child.terminationStatus : 1)
