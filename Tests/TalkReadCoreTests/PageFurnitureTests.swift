import XCTest
@testable import TalkReadCore

/// Running headers, footers and page numbers of a PDF's joined text (Speechify's "skip headers and footers").
final class PageFurnitureTests: XCTestCase {
    /// Pages joined as the importer joins them, with each page's start.
    private func join(_ pages: [String]) -> (text: String, starts: [Int]) {
        var text = "", starts: [Int] = []
        for (i, page) in pages.enumerated() {
            if i > 0 { text += "\n\n" }
            starts.append(text.utf16.count)
            text += page
        }
        return (text, starts)
    }

    private func lines(_ text: String, _ ranges: [Range<Int>]) -> [String] {
        ranges.map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }

    private let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
                         "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango",
                         "uniform", "victor", "whisky", "xray", "yankee", "zulu", "anchor", "barrel", "candle", "dagger"]

    /// Six pages: a running head that alternates between two titles, a "Question n" heading on three pages that does
    /// not follow the page, five body lines, and the page number at the foot.
    private func article() -> [String] {
        (0..<6).map { i in
            var page = [i % 2 == 0 ? "Journal of Law" : "Contract and Tort"]
            if i % 2 == 0 { page.append("Question \(i / 2 + 1)") }
            page += (0..<5).map { "The \(words[(i * 5 + $0) % words.count]) clause binds both parties." }
            page.append("\(i + 1)")
            return page.joined(separator: "\n")
        }
    }

    func testRunningHeadsAndPageNumbersAreFound() {
        let (text, starts) = join(article())
        let found = lines(text, PageFurniture.ranges(text, pageStarts: starts))
        XCTAssertEqual(found.filter { $0 == "Journal of Law" }.count, 3)
        XCTAssertEqual(found.filter { $0 == "Contract and Tort" }.count, 3)
        XCTAssertEqual(found.filter { Int($0) != nil }, ["1", "2", "3", "4", "5", "6"])
        XCTAssertFalse(found.contains { $0.hasPrefix("Question") }, "a heading whose number does not follow the page is kept")
        XCTAssertFalse(found.contains { $0.hasPrefix("The ") }, "body text is kept")
        XCTAssertEqual(found.count, 12)
    }

    func testPageOfAndNumberedHeadsFollowThePage() {
        let pages = (0..<4).map { i in "\(i + 12) Contract Law\nThe \(words[i]) term is implied.\nPage \(i + 1) of 4" }
        let (text, starts) = join(pages)
        let found = lines(text, PageFurniture.ranges(text, pageStarts: starts))
        XCTAssertEqual(found, (0..<4).flatMap { ["\($0 + 12) Contract Law", "Page \($0 + 1) of 4"] })
    }

    func testShortDocumentsAndLongLinesAreLeftAlone() {
        let two = join(["Journal of Law\nBody one.\n1", "Journal of Law\nBody two.\n2"])
        XCTAssertEqual(PageFurniture.ranges(two.text, pageStarts: two.starts), [])
        let long = String(repeating: "A long repeated line of body text. ", count: 4)
        let pages = join((0..<4).map { "\(long)\nThe \(words[$0]) page." })
        XCTAssertEqual(PageFurniture.ranges(pages.text, pageStarts: pages.starts), [])
        XCTAssertEqual(PageFurniture.ranges("", pageStarts: []), [])
    }

    func testSkippedFurnitureIsNotSpoken() {
        let (text, starts) = join(article())
        let skip = PageFurniture.ranges(text, pageStarts: starts)
        let spoken = Speakable.make(text, range: 0..<text.utf16.count, lexicon: [:], skip: skip).text
        XCTAssertFalse(spoken.contains("Journal") || spoken.contains("Tort"), spoken)
        XCTAssertTrue(spoken.contains("Question 2") && spoken.contains("The alpha clause binds both parties."), spoken)
    }
}
