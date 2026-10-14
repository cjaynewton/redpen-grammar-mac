import Foundation

/// The "Your patterns" numbers for the menu panel: fixes this week against last week, and one row per
/// repeat mistake with eight weeks of counts, so a falling bar shows the lesson is sticking.
public struct PatternSummary: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let lesson: String
        public let original: String       // what you wrote, from the latest fix
        public let replacement: String    // what it became
        public let title: String          // the lesson's name, for mistakes better named than shown
        public let spelling: Bool
        public let thisWeek: Int
        public let weeks: [Int]           // oldest first, the last entry is this week
        public let trend: String
    }

    public let thisWeek: Int
    public let lastWeek: Int
    public let rows: [Row]

    public init(_ records: [MistakeRecord], now: Date = Date()) {
        let day = 86_400.0
        func week(_ r: MistakeRecord) -> Int? {  // 7 = this week, 0 = eight weeks ago
            let age = now.timeIntervalSince(r.date)
            guard age >= 0 else { return nil }
            let w = 7 - Int(age / (7 * day))
            return w >= 0 ? w : nil
        }
        thisWeek = records.filter { week($0) == 7 }.count
        lastWeek = records.filter { week($0) == 6 }.count

        var rows: [Row] = []
        for (lesson, recs) in Dictionary(grouping: records, by: \.lesson) {
            var weeks = Array(repeating: 0, count: 8)
            for r in recs { if let w = week(r) { weeks[w] += 1 } }
            guard weeks.contains(where: { $0 > 0 }) else { continue }
            let latest = recs.max { $0.date < $1.date }!
            let now = weeks[7]
            let before = weeks[3..<7].reduce(0, +)
            let usual = Int((Double(before) / 4).rounded())
            let trend: String
            if before == 0 { trend = now > 0 ? "new this week" : "none this week" }
            else if now == 0 { trend = "none this week, down from about \(max(usual, 1)) a week" }
            else if now < usual { trend = "down from about \(usual) a week" }
            else if now > usual { trend = "up from about \(max(usual, 1)) a week" }
            else { trend = "about the same as usual" }
            rows.append(Row(lesson: lesson, original: latest.original, replacement: latest.replacement, title: latest.title,
                            spelling: lesson.hasPrefix("spell"), thisWeek: now, weeks: weeks, trend: trend))
        }
        // Most this week first, then the ones that were common lately.
        self.rows = rows.sorted { ($0.thisWeek, $0.weeks.reduce(0, +), $0.lesson) > ($1.thisWeek, $1.weeks.reduce(0, +), $1.lesson) }
    }
}
