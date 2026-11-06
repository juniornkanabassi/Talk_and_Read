import Foundation
import Darwin

/// Serialises disk work and coalesces repeated snapshots without encoding on the caller's thread.
public final class PersistenceQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TalkRead.persistence", qos: .utility)
    private var pending: [URL: @Sendable () throws -> Void] = [:]
    private var scheduled: DispatchWorkItem?
    private let delay: TimeInterval
    private let report: @Sendable (String) -> Void

    public init(delay: TimeInterval = 0.4, report: @escaping @Sendable (String) -> Void = { Log.write($0) }) {
        self.delay = delay
        self.report = report
    }

    public func save<T: Encodable & Sendable>(_ value: T, to url: URL, immediately: Bool = false) {
        queue.async { [self] in
            pending[url] = {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
            }
            scheduled?.cancel()
            if immediately { writePending(); return }
            let work = DispatchWorkItem { [self] in writePending() }
            scheduled = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    public func perform(_ work: @escaping @Sendable () throws -> Void) {
        queue.async { [self] in
            do { try work() } catch {
                report("Saving documents failed: \(error)")
            }
        }
    }

    /// An operation with its own result must not poison unrelated later saves.
    public func performAndWait(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try work(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Used at shutdown and in tests, after all producers have stopped. Dispatch synchronously
    /// can borrow the caller's thread, so enqueue the work and wait only for its result.
    @discardableResult public func flush() -> Bool {
        let completed = DispatchSemaphore(value: 0)
        let result = FlushResult()
        queue.async { [self] in
            scheduled?.cancel()
            writePending()
            result.succeeded = pending.isEmpty
            completed.signal()
        }
        completed.wait()
        return result.succeeded
    }

    /// The semaphore establishes exclusive access between the queue writer and waiting reader.
    private final class FlushResult: @unchecked Sendable { var succeeded = false }

    /// Synchronous compatibility path for existing CLI reads. New UI loads call this from a detached task.
    public func read<T>(_ work: () throws -> T) rethrows -> T { try queue.sync(execute: work) }

    private func writePending() {
        scheduled = nil
        let writes = pending
        pending.removeAll()
        for (url, write) in writes {
            do { try write() } catch {
                pending[url] = write
                report("Saving \(url.lastPathComponent) failed: \(error)")
            }
        }
    }
}

/// Removed documents stay recoverable until a clean shutdown. On an interrupted shutdown,
/// the persisted library decides whether a held file must be restored.
public struct DocumentHoldingArea: Sendable {
    public let documents: URL
    public let holding: URL
    public init(documents: URL, holding: URL) { self.documents = documents; self.holding = holding }

    public func hold(_ names: [String]) throws {
        let unique = Set(names)
        // Validate every destination before moving anything, then roll back a partial move.
        for name in unique { try validate(name) }
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        for name in unique where FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path) {
            guard !FileManager.default.fileExists(atPath: holding.appendingPathComponent(name).path) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        var moved: [String] = []
        do {
            for name in unique {
                let source = documents.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: holding.appendingPathComponent(name))
                    moved.append(name)
                }
            }
        } catch {
            for name in moved {
                try? FileManager.default.moveItem(at: holding.appendingPathComponent(name), to: documents.appendingPathComponent(name))
            }
            throw error
        }
    }

    public func restore(_ names: [String]) throws {
        let unique = Set(names)
        for name in unique { try validate(name) }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in unique where FileManager.default.fileExists(atPath: holding.appendingPathComponent(name).path) {
            guard !FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        var moved: [String] = []
        do {
            for name in unique {
                let source = holding.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: documents.appendingPathComponent(name))
                    moved.append(name)
                }
            }
        } catch {
            for name in moved {
                try? FileManager.default.moveItem(at: documents.appendingPathComponent(name), to: holding.appendingPathComponent(name))
            }
            throw error
        }
    }

    public func recover(referencedNames: Set<String>?) throws {
        guard FileManager.default.fileExists(atPath: holding.path) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: holding.path).filter { $0 != ".owner" }
        try restore(names.filter { referencedNames?.contains($0) ?? true })
        if FileManager.default.fileExists(atPath: holding.appendingPathComponent(".owner").path) {
            for name in names where FileManager.default.fileExists(atPath: holding.appendingPathComponent(name).path) {
                try FileManager.default.removeItem(at: holding.appendingPathComponent(name))
            }
        } else { try discard() }
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", URL(fileURLWithPath: name).lastPathComponent == name else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    public func discard() throws {
        if FileManager.default.fileExists(atPath: holding.path) { try FileManager.default.removeItem(at: holding) }
    }
}

/// Each live store owns a locked holding folder. Recovery skips stores still using their Undo files.
public final class DocumentHoldingSession: @unchecked Sendable {
    public let files: DocumentHoldingArea
    private let descriptor: Int32

    public init(documents: URL, root: URL, referencedNames: Set<String>?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let recoveryLock = Self.lock(root, wait: true) else { throw CocoaError(.fileWriteUnknown) }
        defer { close(recoveryLock) }
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name != ".owner" {
            let entry = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard UUID(uuidString: name) != nil, let lock = Self.lock(entry) else { continue }
                defer { close(lock) }
                try DocumentHoldingArea(documents: documents, holding: entry).recover(referencedNames: referencedNames)
                try FileManager.default.removeItem(at: entry)
            } else {
                // Migrate the flat holding folder used by earlier builds without touching active session folders.
                let legacy = DocumentHoldingArea(documents: documents, holding: root)
                if referencedNames?.contains(name) ?? true { try legacy.restore([name]) }
                else { try FileManager.default.removeItem(at: entry) }
            }
        }
        let holding = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        guard let descriptor = Self.lock(holding) else { throw CocoaError(.fileWriteUnknown) }
        self.descriptor = descriptor
        files = DocumentHoldingArea(documents: documents, holding: holding)
    }

    private static func lock(_ folder: URL, wait: Bool = false) -> Int32? {
        let descriptor = open(folder.appendingPathComponent(".owner").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else { close(descriptor); return nil }
        return descriptor
    }

    deinit { close(descriptor) }
}
