import AppKit
import Combine
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
            // A blocked metadata writer must not delay synchronous GUI file moves.
            // A background watchdog releases the gate even if this regression returns.
            let snapshotGate = DispatchSemaphore(value: 0)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.writer.perform { continuation.resume(); snapshotGate.wait() }
            }
            let watchdog = DispatchWorkItem { snapshotGate.signal() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1, execute: watchdog)
            let removeStarted = DispatchTime.now().uptimeNanoseconds
            group(undo) { store.remove(original, undoManager: undo) }
            check(Double(DispatchTime.now().uptimeNanoseconds - removeStarted) / 1_000_000_000 < 0.5,
                  "GUI removal does not wait for the blocked metadata writer")
            let restoreStarted = DispatchTime.now().uptimeNanoseconds
            undo.undo()
            check(Double(DispatchTime.now().uptimeNanoseconds - restoreStarted) / 1_000_000_000 < 0.5,
                  "GUI Undo does not wait for the blocked metadata writer")
            watchdog.cancel()
            snapshotGate.signal()
            check(try store.text(original) == "Original extracted text", "independent file queue preserves Undo bytes")
            group(undo) { store.remove(original, undoManager: undo) }
            check(store.flush() && store.items.map(\.id) == [neighbour.id], "remove updates library")
            check(!FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent(original.fileName).path), "remove holds original PDF")
            check(FileManager.default.fileExists(atPath: store.holdingDirectory.appendingPathComponent("\(original.id).txt").path), "remove holds extracted text")
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

            let retry = LibraryItem(id: UUID(), title: "Retry removal", kind: "text", fileName: "retry.txt", added: Date(), position: 12)
            try store.store("Retry text", for: retry)
            try Data("source".utf8).write(to: Paths.documents.appendingPathComponent(retry.fileName))
            _ = store.add(retry)
            let heldRetry = store.holdingDirectory.appendingPathComponent(retry.fileName)
            try FileManager.default.createDirectory(at: heldRetry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("conflict".utf8).write(to: heldRetry)
            group(undo) { store.remove(retry, undoManager: undo) }
            check(store.items.contains(where: { $0.id == retry.id }), "failed GUI hold retains the library item")
            check(store.flush(), "failed GUI hold does not poison persistence")
            let afterGUIFailure: [LibraryItem]? = AppModel.loadJSON(Paths.library)
            check(afterGUIFailure?.contains(where: { $0.id == retry.id }) == true,
                  "failed GUI hold leaves persisted metadata pointing to the original files")
            do {
                try await store.removePersisted(retry)
                check(false, "failed hold rejects removal")
            } catch {
                check(store.items.contains(where: { $0.id == retry.id }), "failed hold retains the library item")
                let savedItems: [LibraryItem]? = AppModel.loadJSON(Paths.library)
                check(savedItems?.contains(where: { $0.id == retry.id }) == true, "failed hold retains the persisted item")
                check(try store.text(retry) == "Retry text", "failed hold keeps extracted text available")
            }
            try FileManager.default.removeItem(at: heldRetry)
            try await store.removePersisted(retry)
            check(!store.items.contains(where: { $0.id == retry.id }), "removal succeeds after a failed hold is corrected")
            check(store.flush(), "failed removal does not poison later persistence")

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

            let racingStore = LibraryStore()
            let racingItem = LibraryItem(id: UUID(), title: "Rollback during quit", kind: "text", fileName: "rollback.txt", added: Date(), position: 7)
            try racingStore.store("Keep this text after rollback", for: racingItem)
            try Data("Keep these original bytes".utf8).write(to: Paths.documents.appendingPathComponent(racingItem.fileName))
            _ = racingStore.add(racingItem)
            check(racingStore.flush(), "rollback fixture is persisted")
            let removalGate = DispatchSemaphore(value: 0)
            // Queue a failure immediately before the removal save, after its file hold succeeded.
            let backupIndex = Paths.library.appendingPathExtension("rollback-backup")
            var changes = 0
            let observation = racingStore.objectWillChange.sink {
                changes += 1
                if changes == 1 {
                    racingStore.writer.perform {
                        removalGate.wait()
                        try FileManager.default.moveItem(at: Paths.library, to: backupIndex)
                        try FileManager.default.createDirectory(at: Paths.library, withIntermediateDirectories: false)
                    }
                } else if changes == 2 {
                    // Let the rollback's next metadata save succeed after the first write truly failed.
                    try? FileManager.default.removeItem(at: Paths.library)
                    try? FileManager.default.moveItem(at: backupIndex, to: Paths.library)
                }
            }
            let removing = Task { () -> Bool in
                do { try await racingStore.removePersisted(racingItem); return false }
                catch { return true }
            }
            while racingStore.items.contains(where: { $0.id == racingItem.id }) { await Task.yield() }
            let quitting = Task { await racingStore.finish() }
            while !racingStore.isFinishing { await Task.yield() }
            // Give the shutdown worker a turn while the removal writer is blocked, then let the writer finish
            // before either main-actor continuation. Cleanup must still wait for the pending rollback.
            try? await Task.sleep(for: .milliseconds(30))
            removalGate.signal()
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.1)
            let rejected = await removing.value
            await quitting.value
            withExtendedLifetime(observation) {}
            check(rejected && racingStore.items.contains(where: { $0.id == racingItem.id }),
                  "shutdown waits for a failed removal to restore its record")
            check(try racingStore.text(racingItem) == "Keep this text after rollback",
                  "shutdown preserves extracted text restored by an in-flight rollback")
            check(try Data(contentsOf: Paths.documents.appendingPathComponent(racingItem.fileName)) == Data("Keep these original bytes".utf8),
                  "shutdown preserves original bytes restored by an in-flight rollback")
            let rollbackItems: [LibraryItem]? = AppModel.loadJSON(Paths.library)
            check(rollbackItems?.contains(where: { $0.id == racingItem.id }) == true,
                  "shutdown persists the final rolled-back library")
        } catch {
            failed += 1
            print("FAIL storage self-test threw \(error)")
        }
        print("Storage self-test: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
