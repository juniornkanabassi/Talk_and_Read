// The Home page's History: reads and dictations merged, filtered, searched and grouped by day. Pure, so it is tested.
import Foundation

public enum HistoryKind: String, Sendable, CaseIterable, Codable {
    case read, dictated
}

/// One row of the merged history. The app's `ReadEntry` and `DictationEntry` convert to this.
public struct HistoryItem: Identifiable, Equatable, Sendable {
    /// The entry's own id, for deleting it. Reads and dictations come from two files, so it is unique only within a kind.
    public let uuid: UUID
    public let kind: HistoryKind
    public let date: Date
    public let app: String?
    public let bundleID: String?
    public let text: String

    /// What the UI uses to tell rows apart: the same UUID in a read and a dictation must not collide.
    public struct ID: Hashable, Sendable { public let kind: HistoryKind; public let uuid: UUID }
    public var id: ID { ID(kind: kind, uuid: uuid) }

    public init(id: UUID, kind: HistoryKind, date: Date, app: String?, bundleID: String?, text: String) {
        self.uuid = id; self.kind = kind; self.date = date; self.app = app; self.bundleID = bundleID; self.text = text
    }
}

public struct HistorySection: Identifiable, Equatable, Sendable {
    /// Start of the day.
    public let day: Date
    public let title: String
    public var items: [HistoryItem]
    public var id: Date { day }
}

/// How to find an app's icon. A bundle id is authoritative: when it is present the name is never used, so a renamed or
/// same-named different app cannot show the wrong icon. The name matters only for old entries that never had a bundle id.
public enum AppLookup: Equatable, Sendable {
    case bundle(String), name(String), generic

    public init(name: String?, bundleID: String?) {
        if let id = bundleID, !id.isEmpty { self = .bundle(id) }
        else if let name, !name.isEmpty, !name.contains("/") { self = .name(name) }
        else { self = .generic }
    }
}

public enum History {
    public static let pageSize = 50

    /// Newest first. Equal dates keep reads before dictations, so the order never flickers.
    public static func merge(_ items: [HistoryItem]) -> [HistoryItem] {
        items.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset
        }.map(\.element)
    }

    /// `kind` nil = all. `search` matches the text or the app name, ignoring case and accents.
    public static func filter(_ items: [HistoryItem], kind: HistoryKind?, search: String) -> [HistoryItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ s: String?) -> Bool { s?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return items.filter { (kind == nil || $0.kind == kind) && (q.isEmpty || has($0.text) || has($0.app)) }
    }

    /// The first `limit` items (already newest first), grouped by calendar day.
    public static func sections(_ items: [HistoryItem], limit: Int, now: Date = Date(), calendar: Calendar = .current) -> [HistorySection] {
        var out: [HistorySection] = []
        for item in items.prefix(limit) {
            let day = calendar.startOfDay(for: item.date)
            if out.last?.day == day {
                out[out.count - 1].items.append(item)   // in place: copying the day's array per entry was quadratic
            } else {
                out.append(HistorySection(day: day, title: dayTitle(day, now: now, calendar: calendar), items: [item]))
            }
        }
        return out
    }

    /// "Today", "Yesterday", then "Thursday 22 October" (with the year when it is not this year).
    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return format(day, calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy", calendar)
    }

    /// "14:32", 24-hour whatever the Mac's locale says.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String { format(date, "HH:mm", calendar) }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()   // built per call: DateFormatter is not Sendable, and a page shows few distinct days
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
