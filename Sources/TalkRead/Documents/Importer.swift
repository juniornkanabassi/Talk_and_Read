// PDF, TXT/MD, RTF/DOCX/HTML, EPUB and web URL -> Document(text, pages?). Stub; owned by WP6.
import Foundation

struct Document {
    let text: String
    let pages: [String]?
}

enum Importer {
    static func load(_ url: URL) async throws -> Document { fatalError("WP6") }
    static func load(web url: URL) async throws -> Document { fatalError("WP6") }
}
