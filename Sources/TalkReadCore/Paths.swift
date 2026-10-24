// Data root and the files inside it; TALKREAD_HOME overrides the root for tests. Owned by WP2.
import Foundation

public enum Paths {
    public static let dataRoot: URL = {
        if let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        // Never renamed with the app (0.5.0 "Talk & Read"): this folder holds the models and settings and is never shown.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talk and Read", isDirectory: true)
    }()
    public static var controlSocket: URL { dataRoot.appendingPathComponent("control.sock") }
    public static var settings: URL { dataRoot.appendingPathComponent("settings.json") }
    public static var library: URL { dataRoot.appendingPathComponent("library.json") }
    public static var documents: URL { dataRoot.appendingPathComponent("Documents", isDirectory: true) }
    public static var history: URL { dataRoot.appendingPathComponent("dictation-history.json") }
    public static var reads: URL { dataRoot.appendingPathComponent("reads.json") }
    public static var pronunciations: URL { dataRoot.appendingPathComponent("pronunciations.json") }
    public static var vocabulary: URL { dataRoot.appendingPathComponent("vocabulary.json") }
    public static var log: URL { dataRoot.appendingPathComponent("talkread.log") }
}

/// Sparkle's update cache for one bundle id (downloaded and extracted updates). Junior: nothing of a previous version
/// stays after an update, so the first launch of a different build clears this folder, and only this folder.
public enum UpdateCache {
    public static func folder(bundleID: String, caches: URL) -> URL {
        caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
    }
    /// A different build from the last launch's, or the first launch that records one.
    public static func shouldClear(lastLaunched: String?, running: String) -> Bool { lastLaunched != running }
}

/// Appends one timestamped line to `talkread.log`; at 5 MB the file is rotated to `talkread.1.log` (one generation).
public enum Log {
    static let maxBytes = 5_000_000
    private static let lock = NSLock()

    public static func write(_ message: String) { write(message, to: Paths.log) }

    static func write(_ message: String, to url: URL) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? handle.write(contentsOf: Data("\(stamp) \(message)\n".utf8))
    }
}
