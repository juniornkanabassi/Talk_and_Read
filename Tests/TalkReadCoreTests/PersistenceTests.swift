import Foundation
import XCTest
@testable import TalkReadCore

final class PersistenceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TalkRead-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCoalescesSnapshotsAndFlushesLatestBeforeQuit() throws {
        let root = try fixture(), file = root.appendingPathComponent("library.json")
        let writer = PersistenceQueue(delay: 60)
        for n in 0..<100 { writer.save(["position": n], to: file) }
        XCTAssertTrue(writer.flush())
        let saved = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, ["position": 99])
    }

    func testEncodingAndFileOperationsRunOffCallerThread() throws {
        let root = try fixture(), marker = Marker()
        let writer = PersistenceQueue(delay: 60)
        for _ in 0..<100 { writer.save(Probe(marker: marker), to: root.appendingPathComponent("probe.json")) }
        writer.perform { marker.record(Thread.isMainThread) }
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(marker.values, [false, false])
    }

    func testFailedSaveReportsFailureAndCanRetryWithoutLosingSnapshot() throws {
        let root = try fixture(), blocker = root.appendingPathComponent("parent")
        try Data().write(to: blocker)
        let file = blocker.appendingPathComponent("library.json")
        let writer = PersistenceQueue(delay: 60, report: { _ in })
        writer.save([1, 2, 3], to: file)
        XCTAssertFalse(writer.flush())
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: file)), [1, 2, 3])
    }

    func testHoldingAndUndoRestoreOriginalAndExtractedText() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let files = DocumentHoldingArea(documents: docs, holding: held)
        for name in ["id.pdf", "id.txt"] { try Data(name.utf8).write(to: docs.appendingPathComponent(name)) }
        try files.hold(["id.pdf", "id.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("id.pdf").path))
        try files.restore(["id.pdf", "id.txt"])
        for name in ["id.pdf", "id.txt"] { XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent(name)), Data(name.utf8)) }
        try files.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("id.pdf").path))
    }

    func testCrashRecoveryKeepsFilesReferencedByPersistedLibrary() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let files = DocumentHoldingArea(documents: docs, holding: held)
        for name in ["live.txt", "removed.txt"] { try Data(name.utf8).write(to: docs.appendingPathComponent(name)) }
        try files.hold(["live.txt", "live.txt", "removed.txt"])
        try files.recover(referencedNames: ["live.txt"])
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("live.txt"), encoding: .utf8), "live.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("removed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
    }

    func testUnknownLibraryRestoresAllHeldFilesAndRefusesTraversal() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let files = DocumentHoldingArea(documents: docs, holding: held)
        try Data("kept".utf8).write(to: docs.appendingPathComponent("kept.txt"))
        try files.hold(["kept.txt"])
        try files.recover(referencedNames: nil)
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("kept.txt"), encoding: .utf8), "kept")
        XCTAssertThrowsError(try files.hold(["../outside.txt"]))
    }

    func testRestoreConflictKeepsBothCopiesForRecovery() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let files = DocumentHoldingArea(documents: docs, holding: held)
        try Data("original".utf8).write(to: docs.appendingPathComponent("id.txt"))
        try files.hold(["id.txt"])
        try Data("new".utf8).write(to: docs.appendingPathComponent("id.txt"))
        XCTAssertThrowsError(try files.recover(referencedNames: ["id.txt"]))
        XCTAssertEqual(try String(contentsOf: held.appendingPathComponent("id.txt"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("id.txt"), encoding: .utf8), "new")
    }

    func testUnrelatedFileOperationFailureDoesNotPoisonSaveFlush() throws {
        let writer = PersistenceQueue(delay: 60, report: { _ in })
        writer.perform { throw CocoaError(.fileWriteNoPermission) }
        let file = try fixture().appendingPathComponent("later.json")
        writer.save(["later"], to: file)
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)), ["later"])
    }

    func testImmediateSaveDoesNotWaitForDebounce() throws {
        let file = try fixture().appendingPathComponent("history.json")
        let writer = PersistenceQueue(delay: 60)
        writer.save(["finished"], to: file, immediately: true)
        let saved = try writer.read { try Data(contentsOf: file) }
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: saved), ["finished"])
    }

    func testAwaitedOperationFailureDoesNotPoisonFlush() async throws {
        let writer = PersistenceQueue(delay: 60, report: { _ in })
        do {
            try await writer.performAndWait { throw CocoaError(.fileWriteNoPermission) }
            XCTFail("expected a file operation error")
        } catch {}
        XCTAssertTrue(writer.flush())
    }

    func testHoldingFailurePreservesOriginalAndExistingHeldCopy() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: docs.appendingPathComponent("id.txt"))
        try Data("held".utf8).write(to: held.appendingPathComponent("id.txt"))
        let files = DocumentHoldingArea(documents: docs, holding: held)
        XCTAssertThrowsError(try files.hold(["id.txt"]))
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("id.txt"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: held.appendingPathComponent("id.txt"), encoding: .utf8), "held")
    }

    func testHoldingPreflightsEveryFileBeforeMovingAny() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        for name in ["original.pdf", "extracted.txt"] {
            try Data(name.utf8).write(to: docs.appendingPathComponent(name))
        }
        try Data("conflict".utf8).write(to: held.appendingPathComponent("extracted.txt"))
        let files = DocumentHoldingArea(documents: docs, holding: held)
        XCTAssertThrowsError(try files.hold(["original.pdf", "extracted.txt"]))
        for name in ["original.pdf", "extracted.txt"] {
            XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.appendingPathComponent("original.pdf").path))
    }

    func testRestorePreflightsEveryFileBeforeMovingAny() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for name in ["original.pdf", "extracted.txt"] { try Data(name.utf8).write(to: docs.appendingPathComponent(name)) }
        let files = DocumentHoldingArea(documents: docs, holding: held)
        try files.hold(["original.pdf", "extracted.txt"])
        try Data("conflict".utf8).write(to: docs.appendingPathComponent("extracted.txt"))
        XCTAssertThrowsError(try files.restore(["original.pdf", "extracted.txt"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("original.pdf").path))
        for name in ["original.pdf", "extracted.txt"] {
            XCTAssertEqual(try Data(contentsOf: held.appendingPathComponent(name)), Data(name.utf8))
        }
    }

    func testSecondLiveStoreCannotRecoverFirstStoresUndoFiles() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: docs.appendingPathComponent("id.txt"))
        let first = try DocumentHoldingSession(documents: docs, root: held, referencedNames: [])
        try first.files.hold(["id.txt"])
        let second = try DocumentHoldingSession(documents: docs, root: held, referencedNames: [])
        try withExtendedLifetime(second) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.files.holding.appendingPathComponent("id.txt").path))
            XCTAssertNoThrow(try first.files.restore(["id.txt"]))
        }
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("id.txt"), encoding: .utf8), "original")
    }

    func testReleasedStoreHoldingIsRecoveredAfterInterruptedQuit() throws {
        let root = try fixture(), docs = root.appendingPathComponent("Documents"), held = root.appendingPathComponent("Removed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for name in ["kept.txt", "removed.txt"] { try Data(name.utf8).write(to: docs.appendingPathComponent(name)) }
        var first: DocumentHoldingSession? = try DocumentHoldingSession(documents: docs, root: held, referencedNames: [])
        let oldFolder = first!.files.holding
        try first!.files.hold(["kept.txt", "removed.txt"])
        first = nil
        let second = try DocumentHoldingSession(documents: docs, root: held, referencedNames: ["kept.txt"])
        withExtendedLifetime(second) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("kept.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("removed.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
        }
    }

    private final class Marker: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []
        func record(_ value: Bool) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    private struct Probe: Encodable, Sendable {
        let marker: Marker
        func encode(to encoder: Encoder) throws {
            marker.record(Thread.isMainThread)
            var container = encoder.singleValueContainer()
            try container.encode("probe")
        }
    }
}
