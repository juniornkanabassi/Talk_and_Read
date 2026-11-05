import Foundation

/// Serialises disk work and coalesces repeated snapshots without encoding on the caller's thread.
public final class PersistenceQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TalkRead.persistence", qos: .utility)
    private var pending: [URL: @Sendable () throws -> Void] = [:]
    private var scheduled: DispatchWorkItem?
    private var fileOperationFailed = false
    private let delay: TimeInterval
    private let report: @Sendable (String) -> Void

    public init(delay: TimeInterval = 0.4, report: @escaping @Sendable (String) -> Void = { Log.write($0) }) {
        self.delay = delay
        self.report = report
    }

    public func save<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async { [self] in
            pending[url] = {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
            }
            scheduled?.cancel()
            let work = DispatchWorkItem { [self] in writePending() }
            scheduled = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    public func perform(_ work: @escaping @Sendable () throws -> Void) {
        queue.async { [self] in
            do { try work() } catch {
                fileOperationFailed = true
                report("Saving documents failed: \(error)")
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
            result.succeeded = pending.isEmpty && !fileOperationFailed
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
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        for name in Set(names) {
            try validate(name)
            let source = documents.appendingPathComponent(name)
            let target = holding.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: target) }
        }
    }

    public func restore(_ names: [String]) throws {
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in Set(names) {
            try validate(name)
            let source = holding.appendingPathComponent(name)
            let target = documents.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    public func recover(referencedNames: Set<String>?) throws {
        guard FileManager.default.fileExists(atPath: holding.path) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: holding.path)
        try restore(names.filter { referencedNames?.contains($0) ?? true })
        try discard()
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
