import AppKit
import Combine
import Foundation
import TalkReadCore

struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    /// pdf|text|markdown|rtf|docx|html|epub|web|pasted
    var kind: String
    /// Copy under Documents/.
    var fileName: String
    var added: Date
    /// Token index of the reading position.
    var position: Int
}

struct ReadEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let app: String?
    /// First 5,000 characters.
    let text: String
    var bundleID: String? = nil
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem]
    @Published private(set) var reads: [ReadEntry]
    private(set) var isFinishing = false
    private var removalsInFlight = 0
    private var removalWaiters: [CheckedContinuation<Void, Never>] = []
    nonisolated let writer = PersistenceQueue()
    nonisolated private let files = DocumentHoldingArea(documents: Paths.documents,
        holding: Paths.dataRoot.appendingPathComponent("Removed documents", isDirectory: true))

    init() {
        let saved: [LibraryItem]? = AppModel.loadJSON(Paths.library)
        items = saved ?? []
        reads = AppModel.loadJSON(Paths.reads) ?? []
        // An unreadable/missing index must never cause held documents to be discarded.
        let referenced = saved.map { Set($0.flatMap(Self.fileNames)) }
        // Recover files before any document can be opened after an interrupted quit.
        do { try files.recover(referencedNames: referenced) } catch { Log.write("Recovering removed documents failed: \(error)") }
    }

    nonisolated static func textURL(_ item: LibraryItem) -> URL {
        Paths.documents.appendingPathComponent("\(item.id.uuidString).txt")
    }
    nonisolated private static func fileNames(_ item: LibraryItem) -> [String] {
        [item.fileName, "\(item.id.uuidString).txt"]
    }
    nonisolated func text(_ item: LibraryItem) throws -> String {
        try writer.read { try String(contentsOf: Self.textURL(item), encoding: .utf8) }
    }
    nonisolated func store(_ text: String, for item: LibraryItem) throws {
        try writer.read {
            try FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
            try text.write(to: Self.textURL(item), atomically: true, encoding: .utf8)
        }
    }
    func add(_ item: LibraryItem) -> LibraryItem {
        guard !isFinishing else { return item }
        items.insert(item, at: 0)
        writer.save(items, to: Paths.library, immediately: true)
        return item
    }
    func setPosition(_ id: UUID, _ token: Int) {
        guard !isFinishing else { return }
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].position != token else { return }
        items[i].position = token
        writer.save(items, to: Paths.library)
    }
    func remove(_ item: LibraryItem, undoManager: UndoManager?, holdFiles: Bool = true) {
        guard !isFinishing else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let saved = items.remove(at: index)
        let names = Self.fileNames(saved)
        if holdFiles { writer.perform { [files] in try files.hold(names) } }
        writer.save(items, to: Paths.library, immediately: true)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            store.restore(saved, at: index, undoManager: undoManager)
        }
        undoManager?.setActionName("Remove from library")
    }
    /// Hold files before changing the index so a failed move leaves a retryable item.
    func removePersisted(_ item: LibraryItem) async throws {
        guard !isFinishing, let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        removalsInFlight += 1
        defer {
            removalsInFlight -= 1
            if removalsInFlight == 0 {
                let waiters = removalWaiters
                removalWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let names = Self.fileNames(item)
        try await writer.performAndWait { [files] in try files.hold(names) }
        guard !isFinishing else {
            try await writer.performAndWait { [files] in try files.restore(names) }
            throw CocoaError(.userCancelled)
        }
        guard items.contains(where: { $0.id == item.id }) else { throw CocoaError(.fileNoSuchFile) }
        remove(item, undoManager: nil, holdFiles: false)
        guard await Task.detached(priority: .utility, operation: { [writer] in writer.flush() }).value else {
            // Keep the original record retryable, including when the index could not be written.
            if !items.contains(where: { $0.id == item.id }) { items.insert(item, at: min(index, items.count)) }
            writer.save(items, to: Paths.library, immediately: true)
            try await writer.performAndWait { [files] in try files.restore(names) }
            _ = await Task.detached(priority: .utility) { [writer] in writer.flush() }.value
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func restore(_ item: LibraryItem, at index: Int, undoManager: UndoManager?) {
        guard !isFinishing else { return }
        guard !items.contains(where: { $0.id == item.id }) else { return }
        let names = Self.fileNames(item)
        writer.perform { [files] in try files.restore(names) }
        items.insert(item, at: min(index, items.count))
        writer.save(items, to: Paths.library, immediately: true)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in store.remove(item, undoManager: undoManager) }
        undoManager?.setActionName("Remove from library")
    }
    func appendRead(_ entry: ReadEntry, limit: Int) {
        guard !isFinishing else { return }
        reads.insert(entry, at: 0)
        if reads.count > limit { reads.removeLast(reads.count - limit) }
        writer.save(reads, to: Paths.reads, immediately: true)
    }
    func deleteRead(_ id: UUID, undoManager: UndoManager?) {
        guard !isFinishing else { return }
        guard let index = reads.firstIndex(where: { $0.id == id }) else { return }
        let entry = reads.remove(at: index)
        writer.save(reads, to: Paths.reads, immediately: true)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in store.restoreRead(entry, at: index, undoManager: undoManager) }
        undoManager?.setActionName("Delete read")
    }
    private func restoreRead(_ entry: ReadEntry, at index: Int, undoManager: UndoManager?) {
        guard !isFinishing else { return }
        guard !reads.contains(where: { $0.id == entry.id }) else { return }
        reads.insert(entry, at: min(index, reads.count))
        writer.save(reads, to: Paths.reads, immediately: true)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in store.deleteRead(entry.id, undoManager: undoManager) }
        undoManager?.setActionName("Delete read")
    }
    @discardableResult func flush() -> Bool { writer.flush() }
    func finish() async {
        // Freeze metadata before yielding: Undo, imports and position timers must not
        // restore a record after cleanup has decided which held files to discard.
        isFinishing = true
        // An admitted removal can still roll back. Freeze cleanup only after its final metadata and files agree.
        if removalsInFlight > 0 {
            await withCheckedContinuation { removalWaiters.append($0) }
        }
        let referenced = Set(items.flatMap(Self.fileNames))
        await Task.detached(priority: .utility) { [writer, files] in
            guard writer.flush() else { return }
            writer.perform { try files.recover(referencedNames: referenced) }
            writer.flush()
        }.value
    }
    func discardRemovedFiles() {
        let referenced = Set(items.flatMap(Self.fileNames))
        writer.perform { [files] in try files.recover(referencedNames: referenced) }
        writer.flush()
    }
}
