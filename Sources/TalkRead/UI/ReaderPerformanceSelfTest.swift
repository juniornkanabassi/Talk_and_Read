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
