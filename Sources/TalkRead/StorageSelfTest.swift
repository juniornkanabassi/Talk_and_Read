import AppKit
import Foundation
import TalkReadCore

/// Exercises the real stores without engines, windows or a production data directory.
@MainActor enum StorageSelfTest {
    static func run() async -> Int32 {
        guard let override = ProcessInfo.processInfo.environment["TALKREAD_HOME"],
              (override.hasPrefix("/private/tmp/") || override.hasPrefix("/tmp/")),
              !FileManager.default.fileExists(atPath: Paths.library.path),
              !FileManager.default.fileExists(atPath: Paths.history.path) else {
            print("FAIL storage self-test needs an empty TALKREAD_HOME under /private/tmp")
            return 1
        }
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func group(_ undo: UndoManager, _ action: () -> Void) {
            undo.beginUndoGrouping(); action(); undo.endUndoGrouping()
        }
        do {
            let store = LibraryStore()
            let undo = UndoManager()
            undo.groupsByEvent = false
            let original = LibraryItem(id: UUID(), title: "Original PDF", kind: "pdf", fileName: "original.pdf", added: Date(), position: 47)
            let neighbour = LibraryItem(id: UUID(), title: "Neighbour", kind: "text", fileName: "neighbour.txt", added: Date(), position: 9)
            try store.store("Original extracted text", for: original)
            try Data("PDF bytes".utf8).write(to: Paths.documents.appendingPathComponent(original.fileName))
            _ = store.add(original); _ = store.add(neighbour)
            check(store.flush(), "initial library writes flush")
            group(undo) { store.remove(original, undoManager: undo) }
            check(store.flush() && store.items.map(\.id) == [neighbour.id], "remove updates library")
            check(!FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent(original.fileName).path), "remove holds original PDF")
            check(FileManager.default.fileExists(atPath: Paths.dataRoot.appendingPathComponent("Removed documents/\(original.id).txt").path), "remove holds extracted text")
            undo.undo()
            check(store.items.map(\.id) == [neighbour.id, original.id] && store.items.last?.position == 47, "Undo restores order and reading position")
            check(try store.text(original) == "Original extracted text", "Undo restores extracted text before a read")
            check(try Data(contentsOf: Paths.documents.appendingPathComponent(original.fileName)) == Data("PDF bytes".utf8), "Undo restores original bytes")
            undo.redo()
            check(store.flush() && !store.items.contains(where: { $0.id == original.id }), "Redo removes library item again")
            undo.undo()
            check(store.flush(), "restored library flushes")
            let reloaded = LibraryStore()
            check(reloaded.items.map(\.id) == [neighbour.id, original.id] && reloaded.items.last?.position == 47, "relaunch preserves restored item and position")

            let read = ReadEntry(id: UUID(), date: Date(), app: nil, text: "A read")
            store.appendRead(read, limit: 200)
            group(undo) { store.deleteRead(read.id, undoManager: undo) }
            undo.undo()
            check(store.reads.first?.id == read.id, "Undo restores read history")
            undo.redo()
            check(store.reads.isEmpty, "Redo deletes read history")

            let dictation = DictationEntry(id: UUID(), date: Date(), text: "A dictation", app: "Notes")
            try JSONEncoder().encode([dictation]).write(to: Paths.history, options: .atomic)
            let controller = DictationController()
            group(undo) { controller.delete(dictation.id, undoManager: undo) }
            check(controller.history.isEmpty, "delete removes dictation")
            undo.undo()
            check(controller.history.first?.id == dictation.id, "Undo restores dictation")
            controller.flushHistory()
            let saved: [DictationEntry]? = AppModel.loadJSON(Paths.history)
            check(saved?.first?.id == dictation.id, "restored dictation is persisted")
            undo.redo()
            check(controller.history.isEmpty, "Redo deletes dictation")
            controller.flushHistory()
            store.flush()
            store.discardRemovedFiles()
            check(try store.text(original) == "Original extracted text", "cleanup leaves restored documents intact")

            // Hold the writer so finish must suspend with its metadata snapshot taken.
            // Real Undo and late import callbacks then run during that suspension.
            let readUndo = UndoManager(), redoUndo = UndoManager()
            readUndo.groupsByEvent = false; redoUndo.groupsByEvent = false
            let keptRead = ReadEntry(id: UUID(), date: Date(), app: nil, text: "Keep this read")
            store.appendRead(read, limit: 200)
            store.appendRead(keptRead, limit: 200)
            group(readUndo) { store.deleteRead(read.id, undoManager: readUndo) }
            group(redoUndo) { store.remove(neighbour, undoManager: redoUndo) }
            redoUndo.undo()
            group(undo) { store.remove(original, undoManager: undo) }
            let writerGate = DispatchSemaphore(value: 0)
            store.writer.perform { writerGate.wait() }
            let closing = Task { await store.finish() }
            while !store.isFinishing { await Task.yield() }
            undo.undo()
            readUndo.undo()
            redoUndo.redo()
            store.setPosition(neighbour.id, 100)
            store.remove(neighbour, undoManager: nil)
            store.deleteRead(keptRead.id, undoManager: nil)
            store.appendRead(read, limit: 200)
            let late = LibraryItem(id: UUID(), title: "Late import", kind: "text", fileName: "late.txt", added: Date(), position: 0)
            _ = store.add(late)
            check(store.items.map(\.id) == [neighbour.id] && store.items.first?.position == 9,
                  "shutdown blocks Undo, Redo, removal, position saves and late imports")
            check(store.reads.map(\.id) == [keptRead.id], "shutdown freezes read history mutations and Undo")
            writerGate.signal()
            await closing.value
            let finishedItems: [LibraryItem]? = AppModel.loadJSON(Paths.library)
            check(finishedItems?.map(\.id) == [neighbour.id], "shutdown persists frozen library without a dangling restored record")
            check(!FileManager.default.fileExists(atPath: LibraryStore.textURL(original).path),
                  "shutdown discards removed text only after metadata is frozen")
        } catch {
            failed += 1
            print("FAIL storage self-test threw \(error)")
        }
        print("Storage self-test: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
