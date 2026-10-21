// One read: chunks -> synthesis ahead of playback -> player -> timeline -> highlight ticks. Stub; owned by WP3.
import Foundation
import TalkReadCore

@MainActor final class ReadSession: ObservableObject {
    enum State: Equatable { case preparing, playing, paused, finished, failed(String) }
    @Published private(set) var state: State = .preparing
    @Published private(set) var currentToken: Int?
    @Published private(set) var currentSentence: Int?
    let text: String
    let tokens: [Token]
    let capture: Capture?
    var firstAudioMs: Int?

    init(text: String, capture: Capture?, voice: Voice, rate: Float, startToken: Int, engines: Engines, lexicon: [String: String]) {
        self.text = text
        self.tokens = TextKit.tokenize(text)
        self.capture = capture
    }

    func start() { fatalError("WP3") }
    func pause() { fatalError("WP3") }
    func resume() { fatalError("WP3") }
    func stop() { fatalError("WP3") }
    func skip(sentences: Int) { fatalError("WP3") }
    func seek(token: Int) { fatalError("WP3") }
    func setRate(_ r: Float) { fatalError("WP3") }
    func setVoice(_ v: Voice) { fatalError("WP3") }
}
