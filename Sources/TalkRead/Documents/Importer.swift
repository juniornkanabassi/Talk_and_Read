// Turns a file or a user-requested web page into plain text for the reader: PDF (page offsets kept), TXT/MD,
// RTF/DOCX/HTML (NSAttributedString), EPUB (ditto + OPF spine) and a one-off web fetch. Owned by WP6.
import AppKit
import PDFKit
import TalkReadCore
import UniformTypeIdentifiers

struct ImportedDocument {
    let title: String
    let text: String
    /// pdf|text|markdown|rtf|docx|html|epub|web
    let kind: String
    /// UTF-16 offset of each PDF page in `text` (pages joined with "\n\n"); nil for other kinds.
    let pageStarts: [Int]?
}

enum Importer {
    enum Failure: LocalizedError, Equatable {
        case unsupported(String), noText, empty(String), unreadable(String), http(Int)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "Talk & Read can't open .\(ext) files."
            case .noText: "This PDF has no selectable text."
            case .empty(let name): "\(name) has no readable text."
            case .unreadable(let name): "Talk & Read couldn't read \(name)."
            case .http(let code): "The page couldn't be loaded (HTTP \(code))."
            }
        }
    }

    static let contentTypes: [UTType] = [.pdf, .plainText, UTType("net.daringfireball.markdown") ?? .plainText, .rtf,
                                         UTType("org.openxmlformats.wordprocessingml.document") ?? .data, .html, .epub]

    static func kind(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": "pdf"
        case "txt", "text": "text"
        case "md", "markdown": "markdown"
        case "rtf": "rtf"
        case "docx": "docx"
        case "html", "htm", "xhtml": "html"
        case "epub": "epub"
        default: nil
        }
    }

    /// Main actor: AppKit's HTML importer must run on the main thread (HTML, EPUB, and web pages use it).
    @MainActor static func load(_ url: URL) throws -> ImportedDocument {
        guard let kind = kind(for: url) else { throw Failure.unsupported(url.pathExtension) }
        let name = url.lastPathComponent
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let doc: ImportedDocument
        switch kind {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            let (text, starts) = pdfText(pdf)
            guard !isBlank(text) else { throw Failure.noText }
            let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            return ImportedDocument(title: nonEmpty(title) ?? fallbackTitle, text: text, kind: kind, pageStarts: starts)
        case "text", "markdown":
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            doc = ImportedDocument(title: fallbackTitle, text: clean(decode(data, encodingName: nil)), kind: kind, pageStarts: nil)
        case "rtf", "docx":
            var attributes: NSDictionary?
            guard let s = try? NSAttributedString(url: url, options: [.documentType: kind == "rtf" ? NSAttributedString.DocumentType.rtf : .officeOpenXML],
                                                  documentAttributes: &attributes) else { throw Failure.unreadable(name) }
            let title = attributes?[NSAttributedString.DocumentAttributeKey.title] as? String
            doc = ImportedDocument(title: nonEmpty(title) ?? fallbackTitle, text: clean(s.string), kind: kind, pageStarts: nil)
        case "html":
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            let page = webText(html: decode(data, encodingName: nil), readability: false)
            doc = ImportedDocument(title: page.title ?? fallbackTitle, text: page.text, kind: kind, pageStarts: nil)
        default:
            doc = try epub(url, fallbackTitle: fallbackTitle)
        }
        guard !isBlank(doc.text) else { throw Failure.empty(name) }
        return doc
    }

    /// Fetches the page once (only when the user asks) and keeps the article text. Ephemeral session: no cookies or cache kept.
    static func load(web url: URL) async throws -> ImportedDocument {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.unsupported(url.scheme ?? "url") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.http(http.statusCode) }
        let html = decode(data, encodingName: response.textEncodingName)
        let page = await MainActor.run { webText(html: html, readability: true) }
        guard !isBlank(page.text) else { throw Failure.empty(url.host ?? "This page") }
        return ImportedDocument(title: page.title ?? url.host ?? "Web page", text: page.text, kind: "web", pageStarts: nil)
    }

    /// Page strings joined with "\n\n", and where each page starts (UTF-16). The PDF reader uses this too, so offsets agree.
    static func pdfText(_ pdf: PDFDocument) -> (text: String, pageStarts: [Int]) {
        var text = "", starts: [Int] = [], offset = 0
        for i in 0..<pdf.pageCount {
            if i > 0 { text += "\n\n"; offset += 2 }
            starts.append(offset)
            let page = pdf.page(at: i)?.string ?? ""
            text += page
            offset += page.utf16.count
        }
        return (text, starts)
    }

    /// HTML to reading text. Everything that could load a resource or isn't prose is removed first, so the AppKit
    /// importer never touches the network. `readability` also drops page chrome and keeps <article>/<main> when present.
    @MainActor static func webText(html: String, readability: Bool) -> (title: String?, text: String) {
        let title = firstMatch("(?is)<title[^>]*>(.*?)</title>", in: html).map(unescape).flatMap(nonEmpty)
        var body = html
        let dropped = ["head", "script", "style", "noscript", "template", "svg", "iframe", "frameset", "object", "applet", "video", "audio", "canvas"]
            + (readability ? ["nav", "header", "footer", "aside", "form"] : [])
        for tag in dropped { body = replace("(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: body, with: " ") }
        body = replace("(?is)<(img|link|meta|base|source|embed|input|track|picture|frame)\\b[^>]*>", in: body, with: " ")
        body = replace("(?is)\\s(style|srcset|src|background|poster)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", in: body, with: "")
        if readability, let main = firstMatch("(?is)<article\\b[^>]*>(.*)</article>", in: body) ?? firstMatch("(?is)<main\\b[^>]*>(.*)</main>", in: body) {
            body = main
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html,
                                                                          .characterEncoding: String.Encoding.utf8.rawValue]
        let text = (try? NSAttributedString(data: Data(body.utf8), options: options, documentAttributes: nil))?.string ?? ""
        return (title, clean(text))
    }

    // MARK: EPUB

    @MainActor private static func epub(_ url: URL, fallbackTitle: String) throws -> ImportedDocument {
        let name = url.lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talkread-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let container = try? XMLDocument(contentsOf: dir.appendingPathComponent("META-INF/container.xml")),
              let opfPath = try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue,
              let opfURL = inside(dir, dir.appendingPathComponent(opfPath)), let opf = try? XMLDocument(contentsOf: opfURL)
        else { throw Failure.unreadable(name) }

        var hrefs: [String: String] = [:]
        for case let item as XMLElement in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue { hrefs[id] = href }
        }
        let spine = ((try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref")) ?? []).compactMap(\.stringValue)
        let title = (try? opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']"))?.first?.stringValue
        let base = opfURL.deletingLastPathComponent()
        var chapters: [String] = []
        for id in spine {
            guard let href = hrefs[id]?.components(separatedBy: "#").first,
                  let file = inside(dir, base.appendingPathComponent(href.removingPercentEncoding ?? href)),
                  let data = try? Data(contentsOf: file) else { continue }
            let text = webText(html: decode(data, encodingName: nil), readability: false).text
            if !isBlank(text) { chapters.append(text) }
        }
        return ImportedDocument(title: nonEmpty(title) ?? fallbackTitle, text: chapters.joined(separator: "\n\n"), kind: "epub", pageStarts: nil)
    }

    /// Refuses any archive path that escapes the unzip folder.
    private static func inside(_ dir: URL, _ url: URL) -> URL? {
        let u = url.standardizedFileURL
        return u.path.hasPrefix(dir.standardizedFileURL.path + "/") ? u : nil
    }

    // MARK: Text helpers

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// CRLF to LF, no attachment placeholders, at most one blank line, no trailing spaces.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        t = replace("[ \\t]+\\n", in: t, with: "\n")
        t = replace("\\n{3,}", in: t, with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    private static func unescape(_ s: String) -> String {
        (CFXMLCreateStringByUnescapingEntities(nil, s as CFString, nil) as String).replacingOccurrences(of: "&nbsp;", with: " ")
    }
    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template) ?? s
    }
}

// MARK: - `TalkRead --selftest-import <dir>` (the lead wires the argv case to `Importer.selfTest(directory:)`)

extension Importer {
    /// Loads every fixture headlessly (no windows) and checks what each must and must not contain. Exit code 0 iff all pass.
    @MainActor static func selfTest(directory: String) async -> Int32 {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(detail)")
            if !ok { failures += 1 }
        }
        func summary(_ d: ImportedDocument) -> String {
            let pages = d.pageStarts.map { " pages=\($0.count) pageStarts=\($0)" } ?? ""
            return "kind=\(d.kind) title=\"\(d.title)\" chars=\(d.text.utf16.count) words=\(TextKit.tokenize(d.text).count)\(pages)"
        }
        // Phrases each fixture must contain, in this order (page order for the PDF, spine order for the EPUB), and must not.
        let expectations: [String: (has: [String], hasNot: [String])] = [
            "sample.pdf": (["The lighthouse keeper of Marlowe Quay", "Page two begins"], []),
            "sample.txt": (["plain text fixture", "café"], []),
            "sample.md": (["Markdown fixture", "Tide tables"], []),
            "sample.rtf": (["Harbour ledger", "rich text fixture"], []),
            "sample.docx": (["Harbour ledger", "Word fixture"], []),
            "sample.html": (["HTML fixture", "Second paragraph"], ["SCRIPT_SHOULD_NOT_APPEAR", "STYLE_SHOULD_NOT_APPEAR"]),
            "sample.epub": (["Chapter one", "Chapter two"], []),
            "web-page.html": (["Site navigation", "The ferry timetable"], ["SCRIPT_SHOULD_NOT_APPEAR"]),
        ]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { kind(for: $0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(files.count >= expectations.count, "fixtures found", "\(files.count) in \(dir.path)")
        for file in files {
            let name = file.lastPathComponent
            do {
                let d = try load(file)
                var why: [String] = []
                var cursor = d.text.startIndex
                for phrase in expectations[name]?.has ?? [] {
                    if let r = d.text.range(of: phrase, range: cursor..<d.text.endIndex) { cursor = r.upperBound } else { why.append("missing \"\(phrase)\" (in order)") }
                }
                for phrase in expectations[name]?.hasNot ?? [] where d.text.contains(phrase) { why.append("contains \"\(phrase)\"") }
                if let starts = d.pageStarts {
                    let page2 = starts.count == 2 ? String((d.text as NSString).substring(from: starts[1]).prefix(15)) : "(\(starts.count) pages)"
                    if !page2.hasPrefix("Page two begins") { why.append("page 2 offset points at \"\(page2)\"") }
                }
                check(why.isEmpty, "load \(name)", why.isEmpty ? summary(d) : why.joined(separator: "; "))
            } catch {
                check(false, "load \(name)", error.localizedDescription)
            }
        }

        // Web page path (readability on) through the real fetch code, with a file URL so no network is touched.
        do {
            let d = try await load(web: dir.appendingPathComponent("web-page.html"))
            let ok = d.text.contains("The ferry timetable") && !d.text.contains("Site navigation") && !d.text.contains("Footer links")
                && !d.text.contains("SCRIPT_SHOULD_NOT_APPEAR") && d.title == "Ferry news & times"
            check(ok, "web article extraction", ok ? summary(d) : "title=\"\(d.title)\" text=\"\(d.text.prefix(160))…\"")
        } catch { check(false, "web article extraction", error.localizedDescription) }

        // Generated cases: a scanned (image-only) PDF says so; Latin-1 text decodes; unknown types are refused.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("talkread-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scanned = PDFDocument()
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.gray.setFill(); r.fill(); return true }
        if let page = PDFPage(image: image) { scanned.insert(page, at: 0) }
        let scannedURL = tmp.appendingPathComponent("scanned.pdf")
        scanned.write(to: scannedURL)
        do { _ = try load(scannedURL); check(false, "scanned PDF refused", "loaded without error") } catch {
            check(error as? Failure == .noText, "scanned PDF refused", "\"\(error.localizedDescription)\"")
        }
        let latin = tmp.appendingPathComponent("latin1.txt")
        try? Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x6F, 0x6E, 0x20, 0x74, 0x68, 0x65, 0x20, 0x71, 0x75, 0x61, 0x79]).write(to: latin)
        let latinText = (try? load(latin))?.text ?? ""
        check(latinText == "Café on the quay", "Latin-1 text decoded", "\"\(latinText)\"")
        do { _ = try load(tmp.appendingPathComponent("notes.pages")); check(false, "unsupported type refused", "loaded") } catch {
            check(error as? Failure == .unsupported("pages"), "unsupported type refused", "\"\(error.localizedDescription)\"")
        }

        print(failures == 0 ? "PASS import self-test" : "FAIL import self-test: \(failures) failing")
        return failures == 0 ? 0 : 1
    }
}
