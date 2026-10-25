// Names for the dictation languages in Settings ▸ Dictation, in the Mac's own language.
import Foundation

enum DictationLanguages {
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    /// "English", "English and French", "English, French and German".
    static func summary(_ codes: [String]) -> String {
        let names = codes.map(name)
        guard names.count > 1 else { return names.first ?? "English" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
