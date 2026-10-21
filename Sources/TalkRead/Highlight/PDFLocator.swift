// Word positions for PDF viewers (Preview) whose elements answer no text bounds (ported from ReadAlong). PDFKit reads the
// file's own text layout (page space); the window's AXPage elements say where each page sits on screen. A phrase that
// occurs more than once is placed only with the selection's page/offset as context (PLAN decision 12), else hidden.
import AppKit
import ApplicationServices
import PDFKit
import TalkReadCore

final class PDFLocator {
    typealias Anchor = (page: Int, offset: Int?)
    private let window: AXUIElement
    private var tokenBounds: [Int: (page: Int, bounds: CGRect)] = [:]
    /// Per PDF page: page space -> the page as displayed (crop box and /Rotate applied, y up), and that displayed size.
    private var pageBoxes: [Int: (transform: CGAffineTransform, size: CGSize)] = [:]
    private var pageElements: [Int: AXUIElement] = [:]
    private let base: Int

    /// nil when the window's AXDocument is not a file PDFKit can open. The extension is not checked: exported PDFs can be
    /// named "Contract.docx - 24_09_2026, 12_08" (Junior's contract, 24 September).
    init?(window: AXUIElement, tokens: [Token], anchor: Anchor?) {
        guard let docPath = axAttribute(window, "AXDocument") as? String,
              let url = URL(string: docPath), url.isFileURL,
              url.pathExtension.lowercased() == "pdf" || Self.hasPDFHeader(url),
              let document = PDFDocument(url: url) else { return nil }
        self.window = window
        let elements = Self.pageElements(in: window)
        guard let base = Self.base(descriptions: elements.mapValues(Self.pageDescription), pageCount: document.pageCount)
        else { return nil }   // which PDF page an AXPage is cannot be told: hide (Sol #12)
        self.base = base
        pageElements = elements
        buildTokenBounds(tokens: tokens, document: document, anchor: anchor)
    }

    /// AXPageIndex's base (pdf index = AXPageIndex - base), from the viewer's own metadata, never guessed (Sol #12):
    /// PDFKit's AXPageIndexDescription ("Page 2", the ordinal whatever the page labels) on any exposed page; else a
    /// viewer exposing every page shows its numbering by the index set (0..<n or 1...n). nil when neither tells.
    static func base(descriptions: [Int: String?], pageCount: Int) -> Int? {
        let bases = Set(descriptions.compactMap { index, text -> Int? in
            let numbers = (text ?? "").split { !$0.isNumber }.compactMap { Int($0) }
            return numbers.count == 1 ? index + 1 - numbers[0] : nil
        })
        if !bases.isEmpty { return bases.count == 1 && [0, 1].contains(bases.first!) ? bases.first : nil }
        guard pageCount > 0 else { return nil }
        let keys = Set(descriptions.keys)
        return keys == Set(0..<pageCount) ? 0 : keys == Set(1...pageCount) ? 1 : nil
    }

    private static func pageDescription(_ element: AXUIElement) -> String? {
        let value = axAttribute(element, "AXPageIndexDescription")
        return (value as? NSAttributedString)?.string ?? value as? String
    }

    /// The selection's page (`AXPageIndex` of the AXPage holding the element) and its offset in that page's text when the
    /// element is the page's text (PDFKit puts the real `AXSelectedTextRange` on the page's AXStaticText).
    static func anchor(element: AXUIElement?, selectionStart: Int?) -> Anchor? {
        var e = element
        for _ in 0..<8 {
            guard let current = e else { return nil }
            if (axAttribute(current, kAXRoleAttribute) as? String) == "AXPage",
               let page = (axAttribute(current, "AXPageIndex") as? NSNumber)?.intValue {
                return (page, CFEqual(current, element!) ? nil : selectionStart)   // the page's own range is {0,0}
            }
            e = axElement(current, kAXParentAttribute)
        }
        return nil
    }

    /// No word of the selection was placed (not in this PDF, a scan with no text layer, or ambiguous).
    var isEmpty: Bool { tokenBounds.isEmpty }

    /// Cocoa screen rect for token `index`, or nil. Re-reads the AXPage frame on every call (scroll and zoom change it);
    /// the PDFKit word bounds were cached at init.
    func rect(forTokenIndex index: Int) -> CGRect? {
        guard let entry = tokenBounds[index], let box = pageBoxes[entry.page], box.size.width > 0, box.size.height > 0,
              let pageAX = pageElement(forPDFIndex: entry.page), let frame = axFrame(pageAX), frame.width > 0,
              // The AXPage frame is the page as displayed; a viewer that drew it otherwise (aspect off) would be guessed.
              abs(frame.height / frame.width - box.size.height / box.size.width) < 0.02 else { return nil }
        let scale = frame.width / box.size.width
        let b = entry.bounds.applying(box.transform)   // rotated pages too (Sol #13)
        let cocoaRect = Locator.convert(topLeftScreenRect: CGRect(x: frame.minX + b.minX * scale,
                                                                  y: frame.minY + (box.size.height - b.maxY) * scale,
                                                                  width: b.width * scale, height: b.height * scale))
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return nil }
        if let clip = scrollAreaClip(from: pageAX), !clip.contains(center) { return nil }
        return cocoaRect
    }

    /// Reads five bytes, so a large image or video open in Preview is not handed to PDFKit.
    private static func hasPDFHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
    }

    // MARK: - Word bounds (PDFKit, cached once)

    /// Tokenises every page, finds where the selection starts (it can start mid word: "ou acknowledge", so up to three
    /// leading words may be skipped), aligns from there with NodeAlignment.alignStream and caches each word's page bounds.
    private func buildTokenBounds(tokens: [Token], document: PDFDocument, anchor: Anchor?) {
        var streamPages: [Int] = [], streamWords: [String] = [], streamRanges: [NSRange] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let text = page.string, !text.isEmpty else { continue }
            for token in TextKit.tokenize(text) {
                streamPages.append(i)
                streamWords.append(token.text.lowercased())
                streamRanges.append(NSRange(location: token.range.lowerBound, length: token.range.count))
            }
        }
        let selectionWords = tokens.map { $0.text.lowercased() }
        guard !streamWords.isEmpty, !selectionWords.isEmpty else { return }

        func starts(matching w: Int, skipping k: Int) -> [Int] {
            guard w > 0, selectionWords.count >= k + w, streamWords.count >= w else { return [] }
            return (0...(streamWords.count - w)).filter { p in (0..<w).allSatisfy { streamWords[p + $0] == selectionWords[k + $0] } }
        }
        guard let candidates = (0..<min(4, selectionWords.count)).lazy.map({ k -> [Int] in
            let five = starts(matching: min(5, selectionWords.count - k), skipping: k)
            return five.isEmpty ? starts(matching: min(3, selectionWords.count - k), skipping: k) : five
        }).first(where: { !$0.isEmpty }) else { return }

        let maps = candidates.map { NodeAlignment.alignStream(streamWords, selectionWords, startingAt: $0) }
        var chosen: Int?
        if let anchor {
            // The anchor is an AXPageIndex too; `base` (from the viewer's metadata) turns it into the PDF page.
            let page = anchor.page - base
            let onPage = candidates.indices.filter { streamPages[candidates[$0]] == page }
            if let offset = anchor.offset {
                chosen = onPage.min { abs(streamRanges[candidates[$0]].location - offset) < abs(streamRanges[candidates[$1]].location - offset) }
            } else if onPage.count == 1 {
                chosen = onPage[0]   // repeated on the anchor page itself with no offset: hide
            }
        } else if let best = maps.indices.max(by: { NodeAlignment.better(maps[$1], than: maps[$0]) }),
                  maps.indices.allSatisfy({ $0 == best || NodeAlignment.better(maps[best], than: maps[$0]) }) {
            chosen = best   // only a strictly better alignment; equal copies with no page context hide
        }
        guard let chosen else { return }
        for (i, q) in maps[chosen] {
            let pageIndex = streamPages[q]
            guard let page = document.page(at: pageIndex) else { continue }
            if pageBoxes[pageIndex] == nil {
                let transform = page.transform(for: .cropBox)
                pageBoxes[pageIndex] = (transform, page.bounds(for: .cropBox).applying(transform).size)
            }
            guard let bounds = page.selection(for: streamRanges[q])?.bounds(for: page) else { continue }
            tokenBounds[i] = (page: pageIndex, bounds: bounds)
        }
    }

    // MARK: - AXPage lookup

    private func pageElement(forPDFIndex index: Int) -> AXUIElement? {
        if let e = pageElements[index + base] { return e }
        pageElements = Self.pageElements(in: window)   // the viewer replaced or added page elements (scroll, zoom)
        return pageElements[index + base]
    }

    /// Depth-first walk of the window (document order) collecting AXPage elements by AXPageIndex.
    private static func pageElements(in window: AXUIElement) -> [Int: AXUIElement] {
        var map: [Int: AXUIElement] = [:]
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let node = stack.popLast(), visited < 8000 {
            visited += 1
            if (axAttribute(node, kAXRoleAttribute) as? String) == "AXPage",
               let index = (axAttribute(node, "AXPageIndex") as? NSNumber)?.intValue {
                map[index] = node
                continue   // a page's own text nodes hold no further pages
            }
            if let children = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children.reversed()) }
        }
        return map
    }

    /// The first AXScrollArea ancestor's frame, in Cocoa coordinates, so a page scrolled out of the viewport hides.
    private func scrollAreaClip(from element: AXUIElement) -> CGRect? {
        var e = element
        for _ in 0..<8 {
            guard let parent = axElement(e, kAXParentAttribute) else { return nil }
            if (axAttribute(parent, kAXRoleAttribute) as? String) == "AXScrollArea" {
                return axFrame(parent).map(Locator.convert(topLeftScreenRect:))
            }
            e = parent
        }
        return nil
    }
}
