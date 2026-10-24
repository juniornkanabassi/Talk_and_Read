// `TalkRead --selftest-asr <dir> --bench [--engines parakeet,apple-speech,apple-dictation] [--context]`: compares recognisers on a
// fixture folder through the live streaming path (real-time 100 ms buffers). Per engine: WER of the cleaned text
// (numbers, £, %, am/pm compared leniently), key terms from terms.txt typed exactly, clips typed exactly, latency from
// the last sample to the transcript, release-to-paste through the real DictationController, and app memory.
// vocabulary.json in the folder is the user's vocabulary (Cleanup; with --context also Apple's contextual strings). Never uses the
// microphone and never types: the paste is a timestamp.
import AppKit
import AVFoundation
import Darwin
import TalkReadCore

@MainActor enum DictationBench {
    static func run(dir: URL) async -> Int32 {
        let clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wav", "m4a"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !clips.isEmpty else { print("bench: no clips in \(dir.path)"); return 1 }
        let vocabulary = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("vocabulary.json")))) ?? [:]
        let terms = ((try? String(contentsOf: dir.appendingPathComponent("terms.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.replacingOccurrences(of: "\\n", with: "\n") }
        let names = argument("--engines")?.split(separator: ",").map(String.init) ?? ["parakeet", "apple-speech", "apple-dictation"]
        print("bench: \(clips.count) clips, \(vocabulary.count) vocabulary entries, \(terms.count) key terms; app footprint at start \(Int(footprintMB())) MB")
        var summary: [String] = []
        var failed = false
        for name in names {
            let asr: DictationASR
            switch name {
            case "parakeet": asr = Transcriber()
            case "apple-speech", "apple-dictation":
                let apple = AppleTranscriber(model: name == "apple-speech" ? .speech : .dictation)
                if CommandLine.arguments.contains("--context") { apple.contextualStrings = Cleanup.terms(vocabulary) }
                asr = apple
            default: print("bench: unknown engine \(name)"); continue
            }
            let before = footprintMB(), started = Date()
            do { try await asr.load(progress: nil) } catch { print("== \(name): not available (\(error.localizedDescription))"); continue }
            print(String(format: "== %@: ready in %.1f s", name, Date().timeIntervalSince(started)))
            print("clip\tWER\tms\tterms\texact\ttext")
            var errors = 0, words = 0, hits = 0, termTotal = 0, exact = 0, latencies: [Double] = [], peak = footprintMB()
            for clip in clips {
                guard let reference = try? String(contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8),
                      let samples = try? Transcriber.samples(of: clip) else { print("\(clip.lastPathComponent)\tunreadable"); return 1 }
                let raw: String, ms: Double
                do { (raw, ms) = try await DictationSelfTest.live(samples, asr) } catch { print("\(clip.lastPathComponent)\tfailed: \(error)"); return 1 }
                peak = max(peak, footprintMB())
                let text = BritishSpelling.apply(Cleanup.apply(raw, vocabulary: vocabulary, removeFillers: true))
                let ref = lenient(reference), e = DictationSelfTest.editDistance(ref, lenient(text))
                let wanted = terms.filter { reference.contains($0) }, got = wanted.filter { text.contains($0) }
                errors += e; words += ref.count; hits += got.count; termTotal += wanted.count; latencies.append(ms)
                if text == reference { exact += 1 }
                let missed = Set(wanted).subtracting(got).map { $0.replacingOccurrences(of: "\n", with: "⏎") }.sorted()
                print(String(format: "%@\t%.0f%%\t%.0f\t%d/%d\t%@\t%@%@", clip.deletingPathExtension().lastPathComponent,
                             100 * Double(e) / Double(max(1, ref.count)), ms, got.count, wanted.count, text == reference ? "yes" : "no",
                             text.replacingOccurrences(of: "\n", with: "⏎"), missed.isEmpty ? "" : "  [missed: \(missed.joined(separator: "; "))]"))
            }
            let e2e = await releaseToPaste(asr, clips: clips)
            let sorted = latencies.sorted()
            let line = String(format: "%@: WER %.1f%%, key terms %d/%d, exact %d/%d, after last sample median %.0f ms (max %.0f), release to paste median %.0f ms (max %.0f) over %d of %d insertions, app memory +%.0f MB loaded, peak %.0f MB",
                              name, 100 * Double(errors) / Double(max(1, words)), hits, termTotal, exact, clips.count,
                              sorted[sorted.count / 2], sorted.last!, e2e.median, e2e.max, e2e.count, e2e.tried, peak - before, peak)
            print(line)
            if e2e.count == 0 { print("bench: \(name) FAIL: no insertion succeeded, release-to-paste was not measured"); failed = true }
            summary.append(line)
            asr.unload()
        }
        summary.append(focusQueryCost())
        print("bench summary:")
        for line in summary { print("  " + line) }
        return failed ? 1 : 0
    }

    /// Read-only, in Junior's frontmost app: the inserter's focus query (one character before the caret), against
    /// reading the field's whole text as it did before V-F.
    private static func focusQueryCost() -> String {
        func ms(_ body: () -> Void) -> Double {
            let start = Date()
            for _ in 0..<5 { body() }
            return Date().timeIntervalSince(start) * 1000 / 5
        }
        let query = ms { _ = Inserter.focusedField(pid: nil) }
        let whole = ms {
            var element: CFTypeRef?, value: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &element) == .success,
               let element { _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) }
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown app"
        return String(format: "insert focus query in %@: %.1f ms (whole-text read %.1f ms)", app, query, whole)
    }

    /// Release (the clip's last buffer, then `stop`) to the moment the controller hands the text to the inserter, for
    /// clips of 4–7 s, through the production DictationController (clean-up, settings and vocabulary reads included).
    static func releaseToPaste(_ asr: DictationASR, clips: [URL]) async -> (median: Double, max: Double, count: Int, tried: Int) {
        var times: [Double] = [], tried = 0
        for clip in clips {
            guard let samples = try? Transcriber.samples(of: clip), (4 * 16_000...7 * 16_000).contains(samples.count) else { continue }
            tried += 1
            let audio = ClipAudio(samples: samples)
            var pasted: Date?
            let controller = DictationController(audio: audio, asr: asr, insert: { _, _, _, _ in pasted = Date(); return .inserted(confirmed: true) })
            controller.quiet = true
            let fed = AsyncStream<Void>.makeStream()
            audio.done = { fed.continuation.finish() }
            try? controller.start(caller: "bench")
            for await _ in fed.stream {}
            let released = Date()
            try? controller.stop(insert: true, caller: "bench")
            _ = await controller.result()
            if let pasted { times.append(pasted.timeIntervalSince(released) * 1000) }
        }
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return (.nan, .nan, 0, tried) }          // no insertion happened: nothing was measured
        return (sorted[sorted.count / 2], sorted.last!, sorted.count, tried)
    }

    /// Plays a clip into the controller like a microphone: 100 ms buffers at real-time pace from `start`.
    private final class ClipAudio: DictationAudio {
        var onBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var done: (() -> Void)?
        let fallbackNotice: String? = nil
        let samples: [Float]
        private var feeding: Task<Void, Never>?
        init(samples: [Float]) { self.samples = samples }

        func start() async throws {
            let onBuffer = onBuffer, samples = samples, done = done
            feeding = Task { @MainActor in
                for start in stride(from: 0, to: samples.count, by: 1600) {
                    if start > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                    if Task.isCancelled { return }
                    onBuffer?(Transcriber.buffer(samples[start..<min(start + 1600, samples.count)]))
                }
                done?()
            }
        }

        func stop() -> [Float] { feeding?.cancel(); return [] }
    }

    /// Words for WER, lenient on written forms: "£55 million" = "55 million pounds", "10%" = "10 per cent", "3:30pm" =
    /// "3 30 p.m.", "the 14th of March" = "14 March", "1st" = "1", and number words up to ninety (and ordinals up to
    /// "twentieth") = digits.
    static func lenient(_ text: String) -> [String] {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: "£\\s?([0-9][0-9.,]*)(\\s?(?:million|billion|thousand|m|bn|k)\\b)?", with: "$1$2 pounds", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bper cent\\b", with: "percent", options: .regularExpression)
        t = t.replacingOccurrences(of: "([0-9])(?:st|nd|rd|th)\\b", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bthe ([0-9]{1,2}) (?:of )?(january|february|march|april|may|june|july|august|september|october|november|december)\\b", with: "$1 $2", options: .regularExpression)
        t = t.replacingOccurrences(of: "([0-9])\\s?([ap])\\.?m\\b\\.?", with: "$1 $2m", options: .regularExpression)
        return DictationSelfTest.normalised(t).map { numbers[$0] ?? $0 }
    }

    private static let numbers: [String: String] = {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                     "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let ordinals = ["", "first", "", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
                        "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth"]
        var map: [String: String] = [:]
        for (i, w) in units.enumerated() { map[w] = "\(i)" }
        for (i, w) in ordinals.enumerated() where !w.isEmpty { map[w] = "\(i)" }   // "second" stays: it is also a unit
        for (i, w) in ["thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() { map[w] = "\((i + 3) * 10)" }
        return map
    }()

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// This process's physical footprint (what Activity Monitor shows as Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
