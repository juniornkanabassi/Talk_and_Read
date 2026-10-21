// Screenshot to listen (R12): the user drags a region with the system tool, Vision reads it, the file is deleted.
// No in-place box for these reads (the karaoke line only).
import AppKit
import Vision

enum ScreenshotCapture {
    /// Why the last `capture()` returned nil, for the player ("Cancelled", "No text found…").
    @MainActor private(set) static var lastFailure: String?

    @MainActor static func capture() async -> String? {
        lastFailure = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talkread-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]   // interactive region, no sound
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
        } catch {
            lastFailure = "Could not start the screenshot tool."
            return nil
        }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            lastFailure = "Cancelled."   // Esc leaves no file
            return nil
        }
        if let text = await recognize(image) { return text }
        lastFailure = CGPreflightScreenCaptureAccess() ? "No text found in that area."
            : "No text found. Without Screen Recording, other apps' windows capture blank."
        return nil
    }

    /// Text in reading order: lines top to bottom, left to right within a line, joined with spaces; a gap taller than a
    /// line starts a new paragraph.
    static func recognize(_ image: CGImage) async -> String? {
        var observations = (try? await OCRLocator.textRequest().perform(on: image)) ?? []
        // ponytail: one retry: a process's first Vision request read nothing once in six self-test runs (21 Oct; not
        // reproduced in 18 cold starts). Costs a second pass only when a region has no text.
        if observations.isEmpty { observations = (try? await OCRLocator.textRequest().perform(on: image)) ?? [] }
        let pieces = observations.compactMap { o in o.topCandidates(1).first.map { (text: $0.string, box: o.boundingBox.cgRect) } }
            .sorted { $0.box.maxY > $1.box.maxY }
        var lines: [[(text: String, box: CGRect)]] = []
        for piece in pieces {
            // Same line when it overlaps the line's vertical middle (normalised coordinates, origin bottom left).
            if let last = lines.last?.first, piece.box.maxY > last.box.midY, piece.box.minY < last.box.midY {
                lines[lines.count - 1].append(piece)
            } else {
                lines.append([piece])
            }
        }
        var text = ""
        var previous: CGRect?
        for line in lines {
            let sorted = line.sorted { $0.box.minX < $1.box.minX }
            let box = sorted.map(\.box).reduce(sorted[0].box) { $0.union($1) }
            if let previous { text += previous.minY - box.maxY > box.height ? "\n\n" : " " }
            text += sorted.map(\.text).joined(separator: " ")
            previous = box
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
