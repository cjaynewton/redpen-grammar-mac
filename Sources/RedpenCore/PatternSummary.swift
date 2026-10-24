import Foundation

/// The "Your patterns" numbers for the menu panel: fixes this week against last week, and one row per
/// repeat mistake with eight weeks of counts, so a falling bar shows the lesson is sticking.
///
/// With the words written each week, fixes are also counted per 1,000 words, and a row's trend compares those
/// rates, so writing less never looks like making fewer mistakes. Rates only use fixes made since Redpen began
/// counting words; fixes from before that have no words to divide by.
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
        /// True when the trend already gives a rate per 1,000 words, so the count needn't sit beside it.
        public var perWords: Bool { trend.contains("per 1,000 words") }
    }

    public let thisWeek: Int
    public let lastWeek: Int
    public let rows: [Row]
    /// Words written in each of the eight weeks, oldest first, the last entry this week.
    public let words: [Int]
    /// Fixes per 1,000 words this week and the week before; nil when that week had too little writing to say.
    public let rateThisWeek: Double?
    public let rateLastWeek: Double?

    /// A week needs at least this many words for a rate: three fixes in 200 words says little.
    public static let minWords = 300

    /// One decimal, without a trailing ".0": "2.5", "3", "0".
    public static func format(_ rate: Double) -> String {
        let r = (rate * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    public init(_ records: [MistakeRecord], words written: [(date: Date, words: Int)] = [], now: Date = Date()) {
        let day = 86_400.0
        func week(_ d: Date) -> Int? {  // 7 = this week, 0 = eight weeks ago
            let age = now.timeIntervalSince(d)
            guard age >= 0 else { return nil }
            let w = 7 - Int(age / (7 * day))
            return w >= 0 ? w : nil
        }
        thisWeek = records.filter { week($0.date) == 7 }.count
        lastWeek = records.filter { week($0.date) == 6 }.count

        var words = Array(repeating: 0, count: 8)
        for w in written where w.words > 0 { if let i = week(w.date) { words[i] += w.words } }
        self.words = words
        // Counting began at the first hour with words; a week that started before then is only partly counted.
        let start = written.filter { $0.words > 0 }.map(\.date).min()
        func counted(_ r: MistakeRecord) -> Bool { start.map { r.date >= $0 } ?? false }
        func rate(_ fixes: Int, _ n: Int) -> Double? { n >= Self.minWords ? Double(fixes) * 1000 / Double(n) : nil }
        rateThisWeek = rate(records.filter { week($0.date) == 7 && counted($0) }.count, words[7])
        rateLastWeek = rate(records.filter { week($0.date) == 6 && counted($0) }.count, words[6])
        let wordsNow = words[7], wordsBefore = words[3..<7].reduce(0, +)

        var rows: [Row] = []
        for (lesson, recs) in Dictionary(grouping: records, by: \.lesson) {
            var weeks = Array(repeating: 0, count: 8), countedWeeks = Array(repeating: 0, count: 8)
            for r in recs {
                guard let w = week(r.date) else { continue }
                weeks[w] += 1
                if counted(r) { countedWeeks[w] += 1 }
            }
            guard weeks.contains(where: { $0 > 0 }) else { continue }
            let latest = recs.max { $0.date < $1.date }!
            let now = weeks[7]
            let before = weeks[3..<7].reduce(0, +)
            let usual = Int((Double(before) / 4).rounded())
            let rNow = rate(countedWeeks[7], wordsNow)
            let rBefore = rate(countedWeeks[3..<7].reduce(0, +), wordsBefore)
            let trend: String
            if let rNow, let rBefore, rBefore > 0 {
                // Enough writing on both sides: compare fixes per 1,000 words, not raw counts.
                let a = Self.format(rNow), b = Self.format(rBefore)
                if a == b { trend = "about the same per 1,000 words" }
                else if rNow < rBefore { trend = "\(a) per 1,000 words, down from \(b)" }
                else { trend = "\(a) per 1,000 words, up from \(b)" }
            } else if start != nil, before > 0 {
                // Redpen counts words, but this week or the weeks before had too little writing counted for a rate.
                // Raw counts could make a light week look like progress, so make no claim.
                trend = "too little writing to compare"
            } else if before == 0 { trend = now > 0 ? "new this week" : "none this week" }
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

    /// The line under the week's fix count, or nil before Redpen has counted any words.
    public var rateLine: String? {
        guard words.contains(where: { $0 > 0 }) else { return nil }
        guard let now = rateThisWeek else { return "Not enough writing this week for a rate per 1,000 words" }
        let a = "\(Self.format(now)) per 1,000 words you wrote"
        return rateLastWeek.map { a + ", \(Self.format($0)) the week before" } ?? a
    }
}
