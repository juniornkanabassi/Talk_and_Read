// AVAudioEngine input tap -> 16 kHz mono Float buffers plus a level meter. The engine exists only while recording:
// an idle running input engine pins Bluetooth headsets into the low-quality HFP profile.
import AVFoundation
import QuartzCore
import TalkReadCore

/// What the dictation controller needs from an audio source (the real `Recorder`, or a fake in the self-test).
@MainActor protocol DictationAudio: AnyObject {
    /// Each converted 16 kHz mono buffer, called on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Input level 0...1, about 30 times a second, on the main thread.
    var onLevel: ((Float) -> Void)? { get set }
    /// Returns once the first buffer has arrived; throws within 1 s without permission or a device, and throws
    /// `RecorderError.stopped` if `stop()` comes first. A new `start()` stops any earlier input.
    func start() async throws
    /// Stops the input and returns everything recorded since `start`.
    func stop() -> [Float]
}

enum RecorderError: LocalizedError {
    case noPermission, noDevice, noAudio, stopped
    var errorDescription: String? {
        switch self {
        case .noPermission: "Microphone access is off for Talk & Read"
        case .noDevice: "No microphone found"
        case .noAudio: "The microphone sent no audio"
        case .stopped: "Recording stopped"
        }
    }
}

/// Stateful any-format -> 16 kHz mono Float32 converter, fed one buffer at a time (no clicks at buffer seams).
final class StreamConverter {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter = c
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    /// RMS in dBFS mapped so -50 dB (room tone) is 0 and 0 dB is 1.
    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))
    }
}

final class Recorder: DictationAudio {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// CoreAudio UID of the input to record from; nil follows the system default. Read at `start` only, so changing it
    /// never touches a recording in progress.
    var microphoneUID: String?
    private var engine: AVAudioEngine?
    private let lock = NSLock()                                 // guards the four below (the tap runs on the audio thread)
    private var samples: [Float] = []
    private var first: Result<Void, Error>?                  // how the wait for the first buffer ended
    private var firstWaiter: CheckedContinuation<Void, Error>?
    /// Bumped by every start and stop: a late buffer, timeout or failure of an older session changes nothing, and an
    /// older start's error path can never stop a newer engine.
    private var session = 0

    @MainActor func start() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw RecorderError.noPermission }
        _ = stop()
        let id = lock.withLock { session += 1; first = nil; return session }
        let onBuffer = onBuffer, onLevel = onLevel                // this session's consumers
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = microphoneUID {                  // before the format is read: it is the chosen device's
            guard let device = Microphone.deviceID(uid: uid), (try? input.auAudioUnit.setDeviceID(device)) != nil else {
                throw RecorderError.noDevice
            }
        }
        let format = input.outputFormat(forBus: 0)   // the chosen input, else the system default
        guard format.sampleRate > 0, format.channelCount > 0, let converter = StreamConverter(from: format) else {
            throw RecorderError.noDevice
        }
        var lastLevel = 0.0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let out = converter.convert(buffer), let data = out.floatChannelData else { return }
            let chunk = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
            let current = self.lock.withLock {
                if self.session == id { self.samples.append(contentsOf: chunk) }
                return self.session == id
            }
            guard current else { return }                          // a late buffer from a stopped engine
            onBuffer?(out)
            let now = CACurrentMediaTime()
            if now - lastLevel >= 1.0 / 30 {
                lastLevel = now
                let level = StreamConverter.level(chunk)
                DispatchQueue.main.async { onLevel?(level) }
            }
            self.finishWait(.success(()), session: id)
        }
        self.engine = engine
        engine.prepare()
        do { try engine.start() } catch { _ = stop(); throw RecorderError.noDevice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finishWait(.failure(RecorderError.noAudio), session: id)
        }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let done: Result<Void, Error>? = lock.withLock {
                    if first == nil { firstWaiter = c }
                    return first
                }
                if let done { c.resume(with: done) }
            }
        } catch {
            if lock.withLock({ session == id }) { _ = stop() }   // its own timeout; after a stop or newer start, not ours
            throw error
        }
    }

    @MainActor func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        lock.withLock { session += 1 }
        finishWait(.failure(RecorderError.stopped), session: nil)
        return lock.withLock { defer { samples = [] }; return samples }
    }

    /// The first outcome wins (first buffer, timeout or stop); later calls and other sessions' calls are ignored.
    /// `session` nil (stop) ends whatever wait is pending.
    private func finishWait(_ result: Result<Void, Error>, session id: Int?) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            guard first == nil, id == nil || id == session else { return nil }
            first = result
            defer { firstWaiter = nil }
            return firstWaiter
        }
        waiter?.resume(with: result)
    }
}
