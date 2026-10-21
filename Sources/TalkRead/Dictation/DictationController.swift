// Hold/toggle dictation: recorder -> transcriber -> cleanup -> inserter, plus history. Stub; owned by WP5.
import Foundation

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let app: String?
}

@MainActor final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording(level: Float, partial: String), transcribing, done(String), failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var history: [DictationEntry] = []

    func start() { fatalError("WP5") }
    func stop(insert: Bool) { fatalError("WP5") }
    func cancel() { fatalError("WP5") }
    func transcribe(file: URL) async throws -> String { fatalError("WP5") }
    func pasteLast() { fatalError("WP5") }
}
