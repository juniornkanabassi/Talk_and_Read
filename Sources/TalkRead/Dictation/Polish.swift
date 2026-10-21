// Optional Apple Intelligence (FoundationModels) punctuation-and-grammar-only rewrite. Off by default; any failure,
// timeout or suspicious answer returns the original text.
import Foundation
import FoundationModels

enum Polish {
    static let instructions = "Fix punctuation, capitalisation and obvious grammar slips in the user's dictated text. Keep their words, meaning, tone and British spelling. Do not add, remove or summarise content. Return only the text."

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    @MainActor static func polish(_ text: String, timeout: Double = 3) async -> String {
        guard isAvailable, !text.isEmpty else { return text }
        var finished = false   // both tasks run on the main actor, so this needs no lock
        let answer: String? = await withCheckedContinuation { done in
            let work = Task { @MainActor in
                let reply = try? await LanguageModelSession(instructions: instructions).respond(to: text).content
                if !finished { finished = true; done.resume(returning: reply) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if !finished { finished = true; work.cancel(); done.resume(returning: nil) }
            }
        }
        guard let polished = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !polished.isEmpty else { return text }
        // ponytail: length guard only; a rewrite of similar length still gets through.
        let ratio = Double(polished.count) / Double(text.count)
        return (0.7...1.3).contains(ratio) ? polished : text
    }
}
