// Headless regression checks. Invoked only by --selftest-reader-performance with a disposable TALKREAD_HOME.
import Foundation
import PDFKit
import TalkReadCore

@MainActor enum ReaderPerformanceSelfTest {
    static func run() async -> Int32 {
        guard let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], home.hasPrefix("/private/tmp/") || home.hasPrefix("/tmp/") else {
            print("FAIL reader-performance: set TALKREAD_HOME to a disposable /private/tmp folder")
            return 2
        }
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            print("\(value ? "PASS" : "FAIL") reader-performance: \(name)")
            if !value { failures += 1 }
        }
        do {
            try FileManager.default.createDirectory(at: Paths.documents, withIntermediateDirectories: true)
            let item = LibraryItem(id: UUID(), title: "Reader fixture", kind: "text", fileName: "unused.txt", added: Date(), position: 0)
            let text = "The harbour opened. A second sentence follows."
            let file = Paths.documents.appendingPathComponent("\(item.id.uuidString).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let doc = try await ReaderDocument.load(item)
            check(doc.text == text && doc.tokens == TextKit.tokenize(text) && doc.sentences.count == 2, "background text load keeps text, tokens and sentences")
            let fixture = try await ReaderDocument.load(item, textOverride: "Snapshot fixture.")
            check(fixture.text == "Snapshot fixture.", "snapshot override uses the same loader")
            let heartbeat = HeartbeatProbe()
            let largeText = String(repeating: text + "\n", count: 10_000)
            let began = ContinuousClock.now
            let large = try await ReaderDocument.load(item, readText: {
                heartbeat.request()
                return largeText
            })
            let elapsed = began.duration(to: ContinuousClock.now)
            check(heartbeat.responded && !heartbeat.workerWasMain && large.tokens.count == doc.tokens.count * 10_000,
                  "main heartbeat runs while large document loads on worker")
            print("MEASURE reader load: \(largeText.utf8.count) bytes, \(large.tokens.count) tokens, total \(elapsed), main heartbeat \(heartbeat.latency) seconds")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/documents/sample.pdf")
            let pdfName = "\(UUID().uuidString).pdf"
            let pdfURL = Paths.documents.appendingPathComponent(pdfName)
            try FileManager.default.copyItem(at: source, to: pdfURL)
            defer { try? FileManager.default.removeItem(at: pdfURL) }
            let pdfItem = LibraryItem(id: UUID(), title: "PDF fixture", kind: "pdf", fileName: pdfName, added: Date(), position: 0)
            let pdf = try await ReaderDocument.load(pdfItem, textOverride: "PDF fixture text")
            check(pdf.pdf != nil && !pdf.pageStarts.isEmpty && pdf.pageStarts.first == 0 && pdf.pdf?.pageCount == pdf.pageStarts.count,
                  "background PDF load extracts page offsets and text")
            let cancelled = Task { try await ReaderDocument.load(item, textOverride: String(repeating: text, count: 10_000)) }
            cancelled.cancel()
            do { _ = try await cancelled.value; check(false, "cancelled load is rejected") }
            catch is CancellationError { check(true, "cancelled load is rejected") }
            catch { check(false, "cancelled load returned \(error)") }
            try FileManager.default.removeItem(at: file)
            do { _ = try await ReaderDocument.load(item); check(false, "missing document reports an error") }
            catch { check(true, "missing document reports an error") }
        } catch { check(false, "fixture setup/load: \(error)") }

        let model = AppModel.shared
        model.settings.showMiniPlayer = false
        model.engines = Engines(neural: SilentEngine(kind: .neural), system: SilentEngine(kind: .system))
        await model.loadVoices()
        let pendingItem = LibraryItem(id: UUID(), title: "Pending read", kind: "text", fileName: "unused.txt", added: Date(), position: 0)
        let previous = model.startSession("The current read continues while another document opens.", capture: nil, id: model.reserve("user"))
        previous.pause()
        let previousOwner = model.owner?.sessionID
        let failedLoad = DocumentLoadProbe()
        model.read(pendingItem, fromToken: nil, readText: { try failedLoad.load(failing: true) })
        await wait { failedLoad.started }
        check(model.session === previous && model.owner?.sessionID == previousOwner && previous.state == .paused,
              "pending file load preserves the current session and ownership")
        failedLoad.release()
        await wait { failedLoad.finished }
        // Allow the waiting main-actor continuation to receive the failure.
        try? await Task.sleep(for: .milliseconds(30))
        check(model.session === previous && model.owner?.sessionID == previousOwner && previous.state == .paused,
              "failed file load preserves the current session and ownership")

        let repeatLoad = DocumentLoadProbe()
        model.read(pendingItem, fromToken: nil, readText: { try repeatLoad.load() })
        await wait { repeatLoad.started }
        model.read(pendingItem, fromToken: nil, readText: { try repeatLoad.load() })
        repeatLoad.release()
        await wait { model.session !== previous }
        check(repeatLoad.calls == 1 && model.session !== previous && model.session?.state == .paused,
              "repeated Play while loading pauses the one pending read")

        let cancelledSession = model.session
        let stoppedLoad = DocumentLoadProbe()
        model.read(pendingItem, fromToken: 1, readText: { try stoppedLoad.load() })
        await wait { stoppedLoad.started }
        model.stopReading()
        stoppedLoad.release()
        await wait { stoppedLoad.finished }
        try? await Task.sleep(for: .milliseconds(30))
        check(model.session === cancelledSession && model.owner == nil && model.liveSession == nil,
              "explicit Stop prevents a pending load from starting later")

        let glyph = ReadHereGlyph()
        let click = glyph.beginClick(readRevision: 12)
        check(glyph.accepts(click, readRevision: 12), "unchanged delayed glyph click may start")
        glyph.stop()   // The ordinary reveal key release stops polling and hides the glyph.
        check(glyph.accepts(click, readRevision: 12), "accepted click survives ordinary reveal key release")
        check(glyph.accepts(click, readRevision: 12), "natural read completion leaves accepted click valid when read revision is unchanged")
        check(!glyph.accepts(click, readRevision: 13), "newer read or explicit stop cancels delayed click")
        glyph.reset()
        check(!glyph.accepts(click, readRevision: 12), "explicit reset cancels delayed click")
        let olderClick = glyph.beginClick(readRevision: 12)
        _ = glyph.beginClick(readRevision: 12)
        check(!glyph.accepts(olderClick, readRevision: 12), "newer glyph click cancels delayed click")

        var leases = ReadHereGlyph.WakeLeases()
        let wakePID: pid_t = 42
        leases.acquire(1, pid: wakePID)
        check(leases.retainedAfterStop([wakePID]) == [wakePID] && leases.restorableAfterStop([wakePID], highlighted: nil).isEmpty,
              "reveal key release retains a pending click's wake")
        leases.acquire(2, pid: wakePID)
        let firstRelease = leases.release(1, highlighted: nil)
        check(firstRelease?.restore == false && leases.contains(wakePID), "overlapping click keeps wake until last lease ends")
        let rejectedRelease = leases.release(2, highlighted: nil)
        check(rejectedRelease?.restore == true && !leases.contains(wakePID), "last rejected click releases its wake")
        leases.acquire(3, pid: wakePID)
        let transferred = leases.release(3, highlighted: wakePID)
        check(transferred?.restore == false && !leases.contains(wakePID), "successful click transfers wake to live highlighter")

        var centralLeases = AXWake.ClickLeaseState()
        centralLeases.retain(wakePID)
        centralLeases.retain(wakePID)
        check(!centralLeases.release(wakePID, keepAwake: false) && centralLeases.contains(wakePID),
              "central wake lease blocks restoration while another click remains")
        check(centralLeases.release(wakePID, keepAwake: false) && !centralLeases.contains(wakePID),
              "last central lease restores a rejected click")
        centralLeases.retain(wakePID)
        check(!centralLeases.release(wakePID, keepAwake: true) && !centralLeases.contains(wakePID),
              "central lease transfers awake state to live highlighter")
        centralLeases.retain(wakePID)
        centralLeases.clear()
        check(!centralLeases.contains(wakePID) && !centralLeases.release(wakePID, keepAwake: false),
              "quit clears central leases and ignores a later stale release")

        let timeoutProbe = TimeoutProbe()
        let calls = AXCallCoordinator { timeoutProbe.set($0) }
        calls.bounded(0.25) {
            calls.call {
                timeoutProbe.expect(0.25)
                calls.bounded(0.1) { calls.call { timeoutProbe.expect(0.1) } }
                timeoutProbe.expect(0.25)
            }
            calls.call { timeoutProbe.expect(0.25) }
        }
        calls.call { timeoutProbe.expect(0) }
        check(timeoutProbe.passed && timeoutProbe.current == 0, "nested AX request bounds restore outer timeout and default")

        let waiting = DispatchSemaphore(value: 0)
        let foregroundDone = DispatchSemaphore(value: 0)
        let concurrent = DispatchGroup()
        concurrent.enter()
        DispatchQueue.global().async {
            calls.bounded(0.1) {
                calls.call { timeoutProbe.expect(0.1) }
                waiting.signal()
                // The foreground must be able to run while this walk is between requests.
                timeoutProbe.recordProgress(foregroundDone.wait(timeout: .now() + 2) == .success)
                calls.call { timeoutProbe.expect(0.1) }
            }
            concurrent.leave()
        }
        concurrent.enter()
        DispatchQueue.global().async {
            calls.bounded(0.25) {
                timeoutProbe.recordProgress(waiting.wait(timeout: .now() + 2) == .success)
                calls.call { timeoutProbe.expect(0.25) }
                foregroundDone.signal()
            }
            concurrent.leave()
        }
        await withCheckedContinuation { continuation in
            concurrent.notify(queue: .global()) { continuation.resume() }
        }
        check(timeoutProbe.passed && timeoutProbe.current == 0, "concurrent AX callers retain their own bounds")
        check(timeoutProbe.progressed, "foreground AX request runs between worker tree-walk requests")

        let probe = WorkerProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await PointerCapture.onWorker { probe.visit() }
                }
            }
        }
        check(probe.calls == 12 && probe.peak == 1 && !probe.usedMainThread, "AX worker is serial and never executes work on the main thread")
        print("reader-performance: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }

    private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class DocumentLoadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var count = 0
        private var done = false
        var calls: Int { lock.withLock { count } }
        var started: Bool { calls > 0 }
        var finished: Bool { lock.withLock { done } }
        func release() { gate.signal() }
        func load(failing: Bool = false) throws -> String {
            lock.withLock { count += 1 }
            _ = gate.wait(timeout: .now() + 5)
            defer { lock.withLock { done = true } }
            if failing { throw CocoaError(.fileNoSuchFile) }
            return "One pending document read, held until the test releases it."
        }
    }

    /// A main-queue acknowledgement while the loader is still on its worker.
    /// A synchronous main-thread loader times out instead of satisfying this check.
    private final class HeartbeatProbe: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        var responded = false
        var workerWasMain = false
        var latency = 0.0
        func request() {
            workerWasMain = Thread.isMainThread
            let began = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.latency = ProcessInfo.processInfo.systemUptime - began
                self.gate.signal()
            }
            responded = gate.wait(timeout: .now() + 3) == .success
        }
    }

    private final class TimeoutProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var timeout: Float = 0
        private var valid = true
        private var progress = true
        var current: Float { lock.withLock { timeout } }
        var passed: Bool { lock.withLock { valid } }
        var progressed: Bool { lock.withLock { progress } }
        func set(_ value: Float) { lock.withLock { timeout = value } }
        func expect(_ value: Float) { lock.withLock { valid = valid && timeout == value } }
        func recordProgress(_ value: Bool) { lock.withLock { progress = progress && value } }
    }

    private final class WorkerProbe: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var active = 0
        var peak = 0
        var usedMainThread = false
        func visit() {
            lock.lock()
            calls += 1; active += 1; peak = max(peak, active)
            usedMainThread = usedMainThread || Thread.isMainThread
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.001)
            lock.lock(); active -= 1; lock.unlock()
        }
    }
}
