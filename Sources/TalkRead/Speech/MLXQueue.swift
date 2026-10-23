// The one serial queue every MLX model runs on (PLAN 0.4.0 decision 2, Sol plan review 0.4.0 rev. 1): Qwen3 and Breeze
// prepare, synthesise, align and unload through the single instance `Engines` owns, and the shared Parakeet aligner is
// used only from inside it, so a cancelled read on one engine finishes draining before the other starts and MLX state
// is never touched concurrently. Also the join-on-cancel stream collection both engines use (Sol inspection 4 #1).
import Foundation
import MLX
import MLXAudioCore
import os

final class MLXQueue: @unchecked Sendable {   // `tail`, `queued` and `idleWaiters` only change under `lock`
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var queued = 0
    private var idleWaiters: [() -> Void] = []

    /// Work queued or running (prepare, synthesise, unload): the idle unload and a model switch wait for it.
    var isBusy: Bool { lock.withLock { queued > 0 } }

    /// True inside work this queue runs (and in the tasks that work starts): the aligner checks it.
    @TaskLocal static var isCurrent = false

    /// Queues `op` behind every earlier call. It counts as busy from the moment this returns, so an unload asked for
    /// now is visible to `isBusy` at once (Sol plan review 0.4.0 #5), and stays busy until `op` has really ended. A
    /// cancelled call gets no result, also when `op` finished regardless (a chunk cancelled while it is aligned).
    @discardableResult func enqueue<T>(_ op: @escaping () async throws -> T) -> Task<T, Error> {
        lock.withLock {
            let previous = tail
            queued += 1
            let t = Task.detached(priority: .userInitiated) { [self] () async throws -> T in
                defer { finished() }
                await previous?.value
                try Task.checkCancellation()
                let result = try await Self.$isCurrent.withValue(true) { try await op() }
                try Task.checkCancellation()
                return result
            }
            tail = Task.detached { _ = try? await t.value }
            return t
        }
    }

    /// Runs `op` after every earlier call has finished. Cancelling the caller cancels `op` (generation checks for it
    /// every frame), so an abandoned chunk frees the GPU within a frame or two.
    func run<T>(_ op: @escaping () async throws -> T) async throws -> T {
        let task = enqueue(op)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Calls `f` once the queue is next idle, at once if it already is (Sol plan review 0.4.0 #5: a model switch that
    /// found the queue busy retries when it drains rather than at the idle timer).
    func whenIdle(_ f: @escaping () -> Void) {
        let now = lock.withLock { () -> Bool in
            if queued == 0 { return true }
            idleWaiters.append(f)
            return false
        }
        if now { f() }
    }

    private func finished() {
        let waiters = lock.withLock { () -> [() -> Void] in
            queued -= 1
            guard queued == 0 else { return [] }
            defer { idleWaiters = [] }
            return idleWaiters
        }
        waiters.forEach { $0() }
    }

    // MARK: - Stream collection

    /// Collects a dependency stream's audio and returns only once the dependency's generation has ended (Sol inspection
    /// 4 #1). `generateStream` generates in a task of its own, which ending the stream (our cancellation) cancels but
    /// nothing joins; that task inherits `probe` and releases it when it ends, so waiting for the probe's release joins
    /// it, whatever our cancellation. Only tasks that inherit task-locals are joined: a producer started detached would
    /// not be, and nothing here would notice (`--fake-slow` case 9 shows both with a producer that outlives the cancel;
    /// Qwen3's and Breeze's start ordinary tasks today). `stream` must create the stream when called, inside the
    /// probe's scope. A cancelled or empty result, or non-finite audio, throws.
    static func collect(_ stream: () -> AsyncThrowingStream<AudioGeneration, Error>) async throws -> (samples: [Float], info: AudioGenerationInfo?) {
        let (released, release) = AsyncStream<Void>.makeStream()
        let joined = Task { for await _ in released {} }   // created outside the binding, and not cancelled with us
        let result: ([Float], AudioGenerationInfo?)
        do {
            result = try await $probe.withValue(Probe(release)) {
                var samples: [Float] = [], info: AudioGenerationInfo?
                for try await event in stream() {
                    if case .audio(let a) = event { samples += a.asArray(Float.self) }
                    if case .info(let i) = event { info = i }
                }
                return (samples, info)
            }
        } catch {
            await joined.value
            throw error
        }
        await joined.value
        try Task.checkCancellation()   // a cancelled stream just ends: its partial chunk is no result
        guard !result.0.isEmpty, result.0.allSatisfy(\.isFinite) else { throw SpeechError.badAudio }
        return result
    }

    /// Dependency generations (Qwen3 and Breeze) still running and the most at once since the last reset (the cancel,
    /// restart and switch self-tests): every task the dependency starts inside `collect` inherits `probe` and holds it
    /// until that task ends.
    static let generations = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
    @TaskLocal private static var probe: Probe?
    private final class Probe: Sendable {
        let release: AsyncStream<Void>.Continuation
        init(_ release: AsyncStream<Void>.Continuation) {
            self.release = release
            MLXQueue.generations.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        }
        deinit {
            MLXQueue.generations.withLock { $0.now -= 1 }
            release.finish()
        }
    }
}
