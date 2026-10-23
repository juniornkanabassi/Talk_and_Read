// Which language a text is in, for choosing the reading voice (PLAN 0.3.0 decision 2). V-B implements it.
import Foundation

public enum Language {
    /// `fr` when the text is clearly French, otherwise `en`.
    public static func detect(_ text: String) -> String { "en" }
}
