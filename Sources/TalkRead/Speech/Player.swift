// AVAudioEngine playback: AVAudioPlayerNode -> Apple's time-domain stretcher 'ipto' (rate 0.5-3.0) -> main mixer,
// 24 kHz mono Float32 (PLAN decision 3). 'ipto' is the engine AVPlayer and QuickTime use for sped-up speech; unlike
// AVAudioUnitTimePitch (a phase vocoder) it keeps voices natural at 2-3x, passes 1x through unchanged and costs a
// tenth of the CPU (spike, 23 Oct: WER at 2.5x 9.4 % vs 11.0 %, at 3x 31.9 % vs 35.4 %). The media clock the highlight reads is the player node's sample time minus the graph's latency.
// `manualRendering` runs the same graph offline (AVAudioEngine manual mode) for the self-test.
import AVFoundation
import FluidAudio
import Foundation
import TalkReadCore

@MainActor final class Player {
    nonisolated static let sampleRate = 24_000.0
    // ponytail: how far the node's clock runs ahead of the graph's output, in media seconds: a fixed look-ahead plus
    // output-side buffering scaled by the rate. Fitted 23 Oct (macOS 27.2) to voiced bursts rendered through this
    // exact graph at 0.5-3x; `SelfTest.clockError` re-measures it. Re-fit if the graph or the stretcher unit changes.
    nonisolated static func graphLatency(rate: Float) -> Double { 0.022 + 0.017 * Double(rate) }

    var rate: Float = 1.0 {
        didSet { rate = min(max(rate, 0.5), 3.0); applyRate() }
    }
    private(set) var isPlaying = false
    private(set) var queuedUntil: Double = 0
    /// Times the node ran dry while `moreComing` was true (a gap between chunks).
    private(set) var starvations = 0
    /// Set by the reader while chunks are still being synthesised, so a dry node counts as a starvation, not idle.
    var moreComing = false
    var onIdle: (() -> Void)?
    /// Output device changed (headphones unplugged, sample rate change), playing or paused: everything queued was
    /// dropped; restart from the clock.
    var onInterrupted: (() -> Void)?
    /// Self-test only: the next `play()` fails as an output device that will not start does.
    var failNextStart = false
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Internal so the self-test can post its configuration-change notification.
    let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    // 'ipto' (kAudioUnitSubType_AUiPodTimeOther); parameter 0 is the rate. It declares 0.5-2.0 but renders correctly to 3.0.
    private let timePitch = AVAudioUnitTimeEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_AUiPodTimeOther,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let format = AVAudioFormat(standardFormatWithSampleRate: Player.sampleRate, channels: 1)!
    private let manual: Bool
    private var pending = 0
    private var generation = 0
    /// Media seconds the node clock is ahead of the media timeline (silence the node played while dry).
    private var shift = 0.0
    private var lastTime = 0.0
    private var engineStop: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// `manualRendering` pulls the real graph offline (AVAudioEngine manual mode) for tests.
    init(manualRendering: Bool = false) {
        manual = manualRendering
        engine.attach(node)
        engine.attach(timePitch)
        if manual {
            // Manual mode is only used by the self-test; failing to enable it is a broken test, so crash loudly.
            try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        } else {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configurationChanged() }
            }
        }
        connect()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func connect() {
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        applyRate()
        engine.prepare()
    }

    private func applyRate() { AudioUnitSetParameter(timePitch.audioUnit, 0, kAudioUnitScope_Global, 0, rate, 0) }

    /// Media seconds (1x timeline) of what is being heard now; frozen while paused, never past `queuedUntil`.
    var currentTime: Double {
        if isPlaying, let t = nodeSeconds() {
            let outputLatency = manual ? 0 : engine.outputNode.presentationLatency * Double(rate)
            lastTime = min(max(t - shift - Self.graphLatency(rate: rate) - outputLatency, 0), queuedUntil)
        }
        return lastTime
    }

    private func nodeSeconds() -> Double? {
        guard let now = node.lastRenderTime, now.isSampleTimeValid, let t = node.playerTime(forNodeTime: now) else { return nil }
        return Double(t.sampleTime) / t.sampleRate
    }

    /// Stops playback, drops everything scheduled and puts the clock back to 0.
    func reset() {
        generation += 1
        pending = 0
        engineStop?.cancel()
        node.stop()
        if !manual { engine.stop() }
        isPlaying = false
        moreComing = false
        queuedUntil = 0
        shift = 0
        lastTime = 0
    }

    /// Schedules the chunk right after the previous one and returns its media start.
    @discardableResult func enqueue(_ c: SynthChunk) -> Double {
        let start = queuedUntil
        var samples = c.samples
        if c.sampleRate != Self.sampleRate {
            // System voices render at 22.05 kHz; one graph format keeps the clock simple.
            samples = (try? AudioConverter(sampleRate: Self.sampleRate).resample(samples, from: c.sampleRate)) ?? []
        }
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return start }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        // A dry node keeps counting silence, so the new chunk starts at the node's "now", not at `start`.
        if pending == 0, isPlaying, let now = nodeSeconds() { shift = max(now - start, 0) }
        pending += 1
        queuedUntil = start + Double(samples.count) / Self.sampleRate
        let gen = generation
        // `.dataRendered`: the node itself ran out, which is what a starvation is (played-back adds device latency).
        node.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            Task { @MainActor in self?.played(gen) }
        }
        return start
    }

    private func played(_ gen: Int) {
        guard gen == generation else { return }
        pending -= 1
        guard pending == 0 else { return }
        if moreComing {
            starvations += 1
        } else {
            onIdle?()
        }
    }

    /// Starts (or resumes) output; `isPlaying` stays false when the engine will not start, which the reader treats as
    /// a failed read.
    /// The first audio engine start in a process costs ~250 ms (cold audio I/O), later ones 30–60 ms. Starting and
    /// stopping a silent engine once at launch, off the main thread, takes that cost before the first read.
    nonisolated static func warmOutput() {
        DispatchQueue.global(qos: .utility).async {
            let engine = AVAudioEngine()
            engine.mainMixerNode.outputVolume = 0
            engine.prepare()
            if (try? engine.start()) != nil { engine.stop() }
        }
    }

    /// Starts the output hardware while the first chunk is still being synthesised, so its ~300 ms start-up overlaps
    /// synthesis instead of following it. Silent until `play()`; a failure here is retried (and reported) by `play()`.
    func warmUp() {
        guard !manual, !engine.isRunning, !failNextStart else { return }
        try? engine.start()
    }

    func play() {
        engineStop?.cancel()
        do {
            if failNextStart { failNextStart = false; throw SpeechError.render("simulated output failure") }
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.write("player: audio engine did not start: \(error.localizedDescription)")
            return
        }
        node.play()
        isPlaying = true
    }

    /// Pauses the node; the engine keeps running for 30 s (instant resume), then pauses too to save power.
    func pause() {
        if isPlaying {
            _ = currentTime
            node.pause()
            isPlaying = false
        }
        guard !manual, engine.isRunning else { return }   // also an engine warmed up for a read paused before its first audio
        let stop = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self, !self.isPlaying { self.engine.pause() } }
        }
        engineStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: stop)
    }

    /// The engine stopped itself and dropped the graph's state. Always reported, because a paused or starved reader
    /// still holds a stale queue and timeline; the reader decides by its own state.
    private func configurationChanged() {
        reset()
        connect()
        onInterrupted?()
    }

    /// Manual-rendering mode only: pulls `seconds` of output (at the output's rate) through the real graph.
    func renderOffline(seconds: Double) throws -> [Float] {
        precondition(manual, "renderOffline needs Player(manualRendering: true)")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw SpeechError.render("no buffer")
        }
        var out: [Float] = []
        var left = AVAudioFrameCount((seconds * engine.manualRenderingFormat.sampleRate).rounded())
        while left > 0 {
            let status = try engine.renderOffline(min(left, buffer.frameCapacity), to: buffer)
            guard status == .success else { throw SpeechError.render("status \(status.rawValue)") }
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            left -= buffer.frameLength
        }
        return out
    }
}
