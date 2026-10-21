// Spoken words -> source word indices (monotonic DP). Owned by WP1.
import Foundation

public enum Alignment {
    /// Monotonic many-to-one map from spoken words to source word indices (nil = unmatched). Case/punct-insensitive,
    /// digits match their spoken English words, initialisms match letter-by-letter, hyphen parts match the compound.
    public static func assign(spoken: [String], source: [String]) -> [Int?] {
        fatalError("WP1")
    }
}
