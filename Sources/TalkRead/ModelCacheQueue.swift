// A cache's file downloads and initial loads must finish before another operation can repair or replace its files.
import Foundation

final class ModelCacheQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let work = lock.withLock {
            let previous = tail
            let work = Task {
                await previous?.value
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            tail = Task { _ = await work.result }
            return work
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
