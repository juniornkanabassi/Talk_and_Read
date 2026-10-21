// @MainActor observable app state; the UI binds only to these members, the control handler routes through them. Stub; owned by WP7 (lead).
import Foundation
import TalkReadCore

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    /// pdf|text|markdown|rtf|docx|html|epub|web|pasted
    var kind: String
    /// Copy under Documents/.
    var fileName: String
    var added: Date
    /// Token index of the reading position.
    var position: Int
}

struct ReadEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let app: String?
    /// First 5,000 characters.
    let text: String
}

enum PermissionKind: String { case accessibility, microphone, screenRecording }

struct Permissions: Equatable {
    var accessibility = false
    var microphone = false
    var screenRecording = false
}

enum ModelState: Equatable { case missing(megabytes: Int), downloading(progress: Double), ready, failed(String) }

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings = Settings()
    @Published private(set) var voices: [Voice] = []
    @Published private(set) var session: ReadSession?
    let dictation = DictationController()
    @Published private(set) var library: [LibraryItem] = []
    @Published private(set) var recentReads: [ReadEntry] = []
    @Published private(set) var permissions = Permissions()
    @Published private(set) var voiceModel: ModelState = .missing(megabytes: 0)
    @Published private(set) var dictationModel: ModelState = .missing(megabytes: 0)

    private init() {}

    func readSelection() { fatalError("WP7") }
    func readScreenshot() { fatalError("WP7") }
    func speak(_ text: String, title: String?, caller: String) throws { fatalError("WP7") }
    func read(_ item: LibraryItem, fromToken: Int?) { fatalError("WP7") }
    func togglePause() { fatalError("WP7") }
    func stopReading() { fatalError("WP7") }
    func skip(_ sentences: Int) { fatalError("WP7") }
    func setSpeed(_ s: Float) { fatalError("WP7") }
    func setVoice(_ id: String) { fatalError("WP7") }

    func importFile(_ url: URL) async throws -> LibraryItem { fatalError("WP7") }
    func importWebPage(_ url: URL) async throws -> LibraryItem { fatalError("WP7") }
    func importText(_ text: String, title: String) -> LibraryItem { fatalError("WP7") }
    func documentText(_ item: LibraryItem) throws -> String { fatalError("WP7") }
    func savePosition(_ item: LibraryItem, token: Int) { fatalError("WP7") }
    func remove(_ item: LibraryItem) { fatalError("WP7") }

    func downloadModels() { fatalError("WP7") }
    func refreshPermissions() { fatalError("WP7") }
    func request(_ p: PermissionKind) { fatalError("WP7") }

    func handle(_ r: ControlRequest) async -> ControlResponse { fatalError("WP7") }
}
