// AVAudioEngine (player node -> time-pitch -> mixer) playback; the media clock the highlight reads. Stub; owned by WP3.
import AVFoundation
import Foundation

@MainActor final class Player {
    var rate: Float = 1.0
    var isPlaying = false
    var currentTime: Double = 0
    var queuedUntil: Double = 0
    var starvations = 0
    var onIdle: (() -> Void)?

    /// `manualRendering` pulls the real graph offline (AVAudioEngine manual mode) for tests.
    init(manualRendering: Bool = false) {}

    func reset() { fatalError("WP3") }
    /// Returns the media start time of the enqueued chunk.
    @discardableResult func enqueue(_ c: SynthChunk) -> Double { fatalError("WP3") }
    func play() { fatalError("WP3") }
    func pause() { fatalError("WP3") }
    /// Manual-rendering mode only: pulls the real graph.
    func renderOffline(seconds: Double) throws -> [Float] { fatalError("WP3") }
}
