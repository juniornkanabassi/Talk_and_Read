import XCTest
@testable import TalkReadCore

final class HistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func item(_ kind: HistoryKind, _ date: Date, _ app: String?, _ text: String) -> HistoryItem {
        HistoryItem(id: UUID(), kind: kind, date: date, app: app, bundleID: nil, text: text)
    }

    func testMergeIsNewestFirstAndStable() {
        let a = item(.read, at(2026, 10, 24, 9), "Safari", "a")
        let b = item(.dictated, at(2026, 10, 24, 11), "Mail", "b")
        let c = item(.read, at(2026, 10, 23, 23, 59), "Notes", "c")
        let d = item(.dictated, at(2026, 10, 24, 9), "Notes", "d")   // same minute as a: the earlier input keeps its place
        XCTAssertEqual(History.merge([a, c, b, d]).map(\.text), ["b", "a", "d", "c"])
    }

    func testDayHeadersAcrossMidnightAndYears() {
        let now = at(2026, 10, 24, 0, 5)
        let items = [item(.read, at(2026, 10, 24, 0, 1), nil, "just after midnight"),
                     item(.read, at(2026, 10, 23, 23, 59), nil, "just before"),
                     item(.dictated, at(2026, 10, 22, 14, 32), nil, "thursday"),
                     item(.dictated, at(2026, 10, 22, 8), nil, "thursday earlier"),
                     item(.read, at(2025, 12, 31, 20), nil, "last year")]
        let sections = History.sections(items, limit: 50, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Thursday 22 October", "Wednesday 31 December 2025"])
        XCTAssertEqual(sections.map { $0.items.count }, [1, 1, 2, 1])
    }

    func testFilterByKind() {
        let items = [item(.read, at(2026, 10, 24, 9), "Safari", "r"), item(.dictated, at(2026, 10, 24, 8), "Mail", "d")]
        XCTAssertEqual(History.filter(items, kind: nil, search: "").count, 2)
        XCTAssertEqual(History.filter(items, kind: .read, search: "").map(\.text), ["r"])
        XCTAssertEqual(History.filter(items, kind: .dictated, search: "").map(\.text), ["d"])
    }

    func testSearchMatchesTextOrAppIgnoringCaseAndSpaces() {
        let items = [item(.read, at(2026, 10, 24, 9), "Safari", "The ferry timetable"),
                     item(.dictated, at(2026, 10, 24, 8), "Mail", "Book the café"),
                     item(.read, at(2026, 10, 24, 7), nil, "No app")]
        XCTAssertEqual(History.filter(items, kind: nil, search: "  FERRY ").map(\.app), ["Safari"])
        XCTAssertEqual(History.filter(items, kind: nil, search: "mail").map(\.text), ["Book the café"])
        XCTAssertEqual(History.filter(items, kind: nil, search: "cafe").count, 1)
        XCTAssertEqual(History.filter(items, kind: .read, search: "mail").count, 0)
        XCTAssertEqual(History.filter(items, kind: nil, search: "zzz").count, 0)
    }

    func testPageOfFiftyThenMore() {
        let now = at(2026, 10, 24, 12)
        let items = (0..<120).map { item(.read, now.addingTimeInterval(-Double($0) * 60), nil, "\($0)") }
        let shown = History.sections(items, limit: History.pageSize, now: now, calendar: calendar).flatMap(\.items)
        XCTAssertEqual(shown.count, 50)
        XCTAssertEqual(shown.last?.text, "49")
        XCTAssertEqual(History.sections(items, limit: History.pageSize * 2, now: now, calendar: calendar).flatMap(\.items).count, 100)
        XCTAssertEqual(History.sections([], limit: 50, now: now, calendar: calendar), [])
    }

    func testTimeIsTwentyFourHour() {
        XCTAssertEqual(History.time(at(2026, 10, 24, 14, 32), calendar: calendar), "14:32")
        XCTAssertEqual(History.time(at(2026, 10, 24, 7, 5), calendar: calendar), "07:05")
    }
}
