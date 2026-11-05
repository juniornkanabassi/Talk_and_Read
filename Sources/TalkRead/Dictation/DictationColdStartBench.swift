// Headless timing through the production file-transcription path. Uses only disposable data and cached models.
import AppKit
import AVFoundation
import Darwin
import FluidAudio
import TalkReadCore

@MainActor enum DictationColdStartBench {
    static func run(file: String) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        assert(!isDisposableHome("/private/tmp/bama-evil/child"))
        assert(!isDisposableHome("relative/child"))
        assert(!isDisposableHome("/private/tmp/bama"))
        guard let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], isDisposableHome(home) else {
            print("cold-start: TALKREAD_HOME must be a disposable directory under /private/tmp/bama/"); return 1
        }
        assert(isDisposableHome(home))
        assert(isDisposableHome(URL(fileURLWithPath: home).resolvingSymlinksInPath().path))
        let wasOffline = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = wasOffline }
        let multilingual = CommandLine.arguments.contains("--cold-start-multilingual")
        let engine: DictationASR = multilingual ? ParakeetV3Transcriber() : Transcriber()
        guard engine.isDownloaded else { print("cold-start: model is not cached; refusing a download"); return 1 }
        let measured = MeasuredASR(engine)
        let decodeMs = NSLockingValue()
        let live = CommandLine.arguments.contains("--cold-start-live")
        let paced = PacedAudio()
        let controller = DictationController(audio: live ? paced : NoAudio(), asr: measured, multilingual: measured,
            insert: { _, _, _, _ in .inserted(confirmed: true) }, decode: { url in
                let start = ProcessInfo.processInfo.systemUptime
                let samples = try Transcriber.samples(of: url)
                decodeMs.set((ProcessInfo.processInfo.systemUptime - start) * 1000)
                return samples
            })
        controller.quiet = true
        controller.languages = multilingual ? ["en", "fr"] : ["en"]
        let url = URL(fileURLWithPath: file)
        do {
            let samples = try Transcriber.samples(of: url)
            guard samples.count >= 16_000 else { print("cold-start: fixture must contain at least one second"); return 1 }
            emit(["event": "configuration", "engine": multilingual ? "multilingual" : "unified",
                  "fixture": url.lastPathComponent, "audioSeconds": Double(samples.count) / 16_000,
                  "pid": getpid(), "memory": usage()])
            if live { return try await runLive(controller, measured, paced, samples) }
            if CommandLine.arguments.contains("--cold-start-prewarm") {
                let started = ProcessInfo.processInfo.systemUptime
                await active { await controller.warmUpIfInstalled() }
                guard measured.isLoaded else { print("cold-start: prewarm failed"); return 1 }
                emit(["event": "prewarm", "loadMs": elapsed(started), "memory": usage()])
            }
            for label in ["cold", "warm", "after_idle_unload", "reload_warm", "after_silent_cache"] {
                var loadMs = 0.0
                if label == "after_silent_cache" {
                    guard controller.unloadModel() else { print("cold-start: cache-prime unload refused"); return 1 }
                    try await Task.sleep(for: .seconds(2))
                    let started = ProcessInfo.processInfo.systemUptime
                    try await active {
                        try await measured.load(progress: nil)
                        _ = try await measured.transcribe(samples: [Float](repeating: 0, count: 16_000))
                    }
                    emit(["event": "silent_cache_prime", "totalMs": elapsed(started), "memory": usage()])
                }
                if label == "after_idle_unload" || label == "after_silent_cache" {
                    guard controller.unloadModel() else { print("cold-start: unload refused"); return 1 }
                    let seconds = label == "after_idle_unload" && CommandLine.arguments.contains("--cold-start-long-idle") ? 600 : 2
                    emit(["event": "idle_wait", "seconds": seconds])
                    try await Task.sleep(for: .seconds(seconds)) // Let model cleanup drain, optionally reproducing ten minutes idle.
                    emit(["event": "unloaded", "memory": usage()])
                }
                if label == "cold" || label == "after_idle_unload" || label == "after_silent_cache" {
                    let started = ProcessInfo.processInfo.systemUptime
                    try await active { try await measured.load(progress: nil) }
                    loadMs = elapsed(started)
                    emit(["event": "load", "stage": label, "loadMs": loadMs, "memory": usage()])
                }
                measured.firstPartialMs = nil
                measured.started = ProcessInfo.processInfo.systemUptime
                let text = try await active { try await controller.transcribe(file: url, caller: "cold-start-bench") }
                guard !text.isEmpty else { print("cold-start: empty transcript"); return 1 }
                let totalMs = elapsed(measured.started)
                // End-to-end includes the separately timed load, as the first real request after idle would.
                emit(["event": "transcription", "stage": label, "totalMs": totalMs,
                      "loadMs": loadMs, "endToEndMs": totalMs + loadMs,
                      "decodeMs": decodeMs.get(), "firstPartialMs": measured.firstPartialMs as Any? ?? NSNull(),
                      "text": text, "memory": usage()])
            }
            let before = usage(), started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(2))
            let after = usage()
            emit(["event": "resident_idle", "seconds": elapsed(started) / 1000,
                  "cpuPercent": ((after["cpuSeconds"] ?? 0) - (before["cpuSeconds"] ?? 0)) / (elapsed(started) / 1000) * 100,
                  "memory": after])
            guard controller.unloadModel() else { print("cold-start: final unload refused"); return 1 }
            return 0
        } catch { print("cold-start: FAIL \(error)"); return 1 }
    }

    /// The live path: start (the hotkey), the clip fed at speaking pace, stop, then the wait for the text. Each stage
    /// reproduces what the idle timer leaves behind, with this throwaway process's own Core ML cache deleted to stand in
    /// for macOS purging caches under low disk space.
    private static func runLive(_ controller: DictationController, _ measured: MeasuredASR, _ paced: PacedAudio,
                                _ samples: [Float]) async throws -> Int32 {
        let name = ProcessInfo.processInfo.processName
        guard name.hasPrefix("TalkRead-cold-") else { print("cold-start: --cold-start-live needs a TalkRead-cold-* copy of the binary"); return 1 }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name).appendingPathComponent("com.apple.e5rt.e5bundlecache")
        func purge() { try? FileManager.default.removeItem(at: cache) }
        for cue in ["Tink", "Pop"] {   // constructed only, never played
            let started = ProcessInfo.processInfo.systemUptime
            let sound = NSSound(named: cue)
            emit(["event": "cue", "name": cue, "found": sound != nil, "initMs": elapsed(started)])
        }
        paced.samples = samples
        purge()
        let stages: [(String, () -> Bool)] = [
            ("purged_unloaded", { true }),
            ("warm", { true }),
            ("old_idle_unload", { controller.unloadModel() }),
            ("old_idle_unload_then_purge", { let ok = controller.unloadModel(); purge(); return ok }),
            ("new_idle_keep_then_purge", { let ok = controller.unloadModel(keepSelected: true); purge(); return ok }),
        ]
        for (label, prepare) in stages {
            guard prepare() else { print("cold-start: unload refused before \(label)"); return 1 }
            if label != "purged_unloaded", label != "warm" { try await Task.sleep(for: .seconds(2)) }
            emit(["event": "before_utterance", "stage": label, "loaded": measured.isLoaded, "memory": usage()])
            paced.delivered = false
            measured.loadDone = nil
            let pressed = ProcessInfo.processInfo.systemUptime
            measured.started = pressed
            measured.firstPartialMs = nil
            let text: String? = try await active {
                try controller.start(caller: "cold-start-bench")
                while !paced.delivered { try await Task.sleep(for: .milliseconds(5)) }
                let speechMs = elapsed(pressed), loadedAtStop = measured.isLoaded
                let stopped = ProcessInfo.processInfo.systemUptime
                try controller.stop(insert: true, caller: "cold-start-bench")
                let text = await controller.result()
                emit(["event": "utterance", "stage": label, "speechMs": speechMs, "stopToTextMs": elapsed(stopped),
                      "loadedAtStop": loadedAtStop, "loadDoneMs": measured.loadDone.map { ($0 - pressed) * 1000 } as Any? ?? NSNull(),
                      "firstPartialMs": measured.firstPartialMs as Any? ?? NSNull(), "text": text ?? NSNull(), "memory": usage()])
                return text
            }
            guard let text, !text.isEmpty else { print("cold-start: empty transcript at \(label)"); return 1 }
        }
        guard controller.unloadModel() else { print("cold-start: final unload refused"); return 1 }
        purge()
        return 0
    }

    private static func isDisposableHome(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let root = URL(fileURLWithPath: "/private/tmp/bama").resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }

    private static func elapsed(_ start: Double) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    /// Match AppModel's activity token during work, and release it throughout the idle measurements.
    private static func active<T>(_ work: () async throws -> T) async rethrows -> T {
        let token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Dictation timing fixture")
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try await work()
    }
    private static func emit(_ fields: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("COLD_START_JSON " + line) }
    }
    private static func usage() -> [String: Double] {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return [:] }
        return ["residentMiB": Double(info.ri_resident_size) / 1_048_576,
                "footprintMiB": Double(info.ri_phys_footprint) / 1_048_576,
                "cpuSeconds": Double(info.ri_user_time + info.ri_system_time) / 1e9]
    }

    /// Keeps the production controller in use while recording the recogniser's first callback.
    private final class MeasuredASR: DictationASR {
        let engine: DictationASR
        var started = 0.0
        var firstPartialMs: Double?
        init(_ engine: DictationASR) { self.engine = engine }
        var isLoaded: Bool { engine.isLoaded }
        var isLoading: Bool { engine.isLoading }
        var isDownloaded: Bool { engine.isDownloaded }
        var onLoadingChange: (() -> Void)? {
            get { engine.onLoadingChange }
            set { engine.onLoadingChange = newValue }
        }
        var loadDone: Double?
        func load(progress: ((Double) -> Void)?) async throws {
            try await engine.load(progress: progress)
            if loadDone == nil { loadDone = ProcessInfo.processInfo.systemUptime }
        }
        func unload() -> Bool { engine.unload() }
        func run(_ audio: AsyncStream<AVAudioPCMBuffer>, partial: @escaping @MainActor (String) -> Void) async throws -> Transcript {
            try await engine.run(audio, partial: { [self] text in
                if !text.isEmpty, firstPartialMs == nil { firstPartialMs = elapsed(started) }
                partial(text)
            })
        }
    }
    private final class NoAudio: DictationAudio {
        var onBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var fallbackNotice: String? { nil }
        func start() async throws { throw RecorderError.noDevice }
        func stop() -> [Float] { [] }
    }
    /// Feeds the clip in 100 ms buffers at speaking pace, as the microphone would, from `start()` until `stop()`.
    private final class PacedAudio: DictationAudio {
        var onBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var fallbackNotice: String? { nil }
        var samples: [Float] = []
        var delivered = false
        private var feeder: Task<Void, Never>?
        func start() async throws {
            let samples = samples, onBuffer = onBuffer, begin = ContinuousClock.now
            feeder = Task { [weak self] in
                for (i, start) in stride(from: 0, to: samples.count, by: 1_600).enumerated() {
                    guard !Task.isCancelled else { return }
                    onBuffer?(Transcriber.buffer(samples[start..<min(start + 1_600, samples.count)]))
                    try? await Task.sleep(until: begin + .milliseconds(100 * (i + 1)), clock: .continuous)
                }
                self?.delivered = true
            }
        }
        func stop() -> [Float] { feeder?.cancel(); feeder = nil; return [] }
    }
    private final class NSLockingValue: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    }
}
