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
    public static let folderName = "org.sparkle-project.Sparkle"

    public enum Refusal: Error, Equatable { case invalidBundleID, symlink(String), notADirectory(String), failed(String) }

    /// A different build from the last launch's, or the first launch that records one.
    public static func shouldClear(lastLaunched: String?, running: String) -> Bool { lastLaunched != running }

    /// One path component of [A-Za-z0-9.-] whose dot-separated parts are all non-empty, so never "", ".", ".." or a
    /// path: the folder is always <caches>/<bundle id>/org.sparkle-project.Sparkle.
    public static func isValidBundleID(_ id: String) -> Bool {
        id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }
            && id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }

    /// Removes <caches>/<bundleID>/org.sparkle-project.Sparkle and returns the bytes of the files it held (nil: none).
    /// It can never delete anything else. Every step goes through an open directory descriptor: the bundle folder and
    /// the Sparkle folder are opened with O_NOFOLLOW (a symlink there is refused, nothing is removed), and inside, each
    /// entry is examined without following links (fstatat AT_SYMLINK_NOFOLLOW), descended only by openat O_NOFOLLOW and
    /// removed with unlinkat relative to its parent's descriptor, so a link is removed as a link and a folder swapped
    /// for a link mid-way fails to open instead of redirecting the walk. Path-based removal (FileManager) would follow
    /// a symlinked parent.
    public static func clear(bundleID: String, caches: URL) throws -> Int? {
        guard isValidBundleID(bundleID) else { throw Refusal.invalidBundleID }
        let root = open(caches.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        guard let bundle = try openFolder(root, bundleID) else { return nil }
        defer { close(bundle) }
        guard let sparkle = try openFolder(bundle, folderName) else { return nil }
        let bytes: Int
        do { bytes = try empty(sparkle); close(sparkle) } catch { close(sparkle); throw error }
        guard unlinkat(bundle, folderName, AT_REMOVEDIR) == 0 else { throw failure(folderName) }
        return bytes
    }

    /// The child folder's descriptor; nil when it does not exist; refused when it is a symlink or not a folder.
    private static func openFolder(_ parent: Int32, _ name: String) throws -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { return fd }
        switch errno {
        case ENOENT: return nil
        case ELOOP, ENOTDIR:   // macOS gives ENOTDIR for a symlink under O_DIRECTORY | O_NOFOLLOW; say which it was
            var info = stat()
            let link = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFLNK
            throw link ? Refusal.symlink(name) : Refusal.notADirectory(name)
        default: throw failure(name)
        }
    }

    private static func failure(_ name: String) -> Refusal { .failed("\(name): \(String(cString: strerror(errno)))") }

    /// Removes everything inside the folder `dir`, depth first; returns the bytes of the regular files removed.
    private static func empty(_ dir: Int32) throws -> Int {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw failure("listing") }
        var names: [String] = []
        while let entry = readdir(stream) {
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(stream)
        var bytes = 0
        for name in names {
            var info = stat()
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(name) }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard let child = try openFolder(dir, name) else { continue }
                do { bytes += try empty(child); close(child) } catch { close(child); throw error }
                guard unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw failure(name) }
            } else {
                if info.st_mode & S_IFMT == S_IFREG { bytes += Int(info.st_size) }
                guard unlinkat(dir, name, 0) == 0 else { throw failure(name) }   // a link goes, its target stays
            }
        }
        return bytes
    }
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
