// Serialised pasteboard transactions: snapshot all items, do the work, restore before the next one starts. Stub; owned by WP4.
import Foundation

actor PasteboardGate {
    static let shared = PasteboardGate()

    func transaction<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        try await body()   // WP4: snapshot and restore around this call
    }
}
