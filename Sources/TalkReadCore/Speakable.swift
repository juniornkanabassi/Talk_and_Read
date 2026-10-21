// Source text -> what the TTS engine hears, with an index map back to the source. Owned by WP1.
import Foundation

public struct Speakable: Sendable {
    /// What the engine hears.
    public let text: String

    public init(text: String) { self.text = text }

    public static func make(_ source: String, range: Range<Int>, lexicon: [String: String]) -> Speakable {
        fatalError("WP1")
    }

    /// Speakable UTF-16 range -> source UTF-16 range.
    public func sourceRange(_ r: Range<Int>) -> Range<Int> {
        fatalError("WP1")
    }
}
