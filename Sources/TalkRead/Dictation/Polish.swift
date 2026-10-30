// Optional Apple Intelligence (FoundationModels) punctuation-and-grammar-only rewrite. Off by default; any failure,
// timeout or suspicious answer returns the original text. Each line is polished on its own and the line breaks (paragraph
// breaks included) are put back exactly, so the model can neither merge nor move a paragraph.
import Foundation
import FoundationModels
import TalkReadCore

enum Polish {
    static let instructions = "Fix punctuation, capitalisation and obvious grammar slips in the user's dictated text. Keep their words, meaning, tone and British spelling. The text may mix English and French, or be in another language: keep every sentence in the language it was said in and never translate. Do not add, remove or summarise content. Return only the text, as a single paragraph."

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    /// The lines polished at the same time, each with its own time limit; a line whose answer is empty, has a line break
    /// in it, is much longer or shorter, or lost over 20% of the words keeps its original.
    @MainActor static func polish(_ text: String, timeout: Double = 3) async -> String {
        guard isAvailable, !text.isEmpty else { return text }
        let lines = text.components(separatedBy: "\n")
        let done = await withTaskGroup(of: (Int, String).self) { group in
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                group.addTask { @MainActor in (i, await polishLine(line, timeout: timeout)) }
            }
            return await group.reduce(into: [Int: String]()) { $0[$1.0] = $1.1 }
        }
        return lines.indices.map { done[$0] ?? lines[$0] }.joined(separator: "\n")
    }

    @MainActor private static func polishLine(_ text: String, timeout: Double) async -> String {
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
        guard let polished = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !polished.isEmpty, !polished.contains("\n") else { return text }
        // ponytail: length and word-overlap guards; a same-length rewrite that keeps 80% of the words still gets through.
        let ratio = Double(polished.count) / Double(text.count)
        return (0.7...1.3).contains(ratio) && Cleanup.keepsWords(polished, of: text) ? polished : text
    }
}
