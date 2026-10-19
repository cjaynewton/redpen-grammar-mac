import Foundation

/// A private record of the fixes you accept, so Redpen can show which mistakes keep coming back.
/// Only the lesson, the flagged words and the fix are stored, never the surrounding text. It stays on this Mac.
public struct MistakeRecord: Codable, Sendable {
    public let date: Date
    public let lesson: String
    public let title: String
    public let original: String
    public let replacement: String
    public let app: String

    public init(date: Date, lesson: String, title: String, original: String, replacement: String, app: String) {
        self.date = date; self.lesson = lesson; self.title = title
        self.original = original; self.replacement = replacement; self.app = app
    }
}

public final class Mistakes: @unchecked Sendable {
    public static let shared = Mistakes(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Redpen/mistakes.jsonl"))

    let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func record(_ issue: Issue, replacement: String, app: String, at date: Date = Date()) {
        guard let lesson = Lessons.lesson(for: issue) else { return }
        let rec = MistakeRecord(date: date, lesson: lesson.id, title: lesson.title, original: issue.original,
                                replacement: replacement, app: app)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(rec) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
            Private.lock(url)
        }
    }

    public func all() -> [MistakeRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(MistakeRecord.self, from: Data($0.utf8)) }
    }

    /// How many times this lesson came up in the last `days` days.
    public func count(_ lessonID: String, days: Int = 30, now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return all().filter { $0.lesson == lessonID && $0.date >= since }.count
    }

    /// Plain-text weekly lesson: the mistakes that came back most this week, each with its rule, and
    /// whether each is coming back more or less than the week before.
    public func report(now: Date = Date()) -> String {
        let recs = all()
        let week = now.addingTimeInterval(-7 * 86_400), prior = now.addingTimeInterval(-14 * 86_400)
        let this = recs.filter { $0.date >= week }
        let last = recs.filter { $0.date >= prior && $0.date < week }
        guard !recs.isEmpty else {
            return "No fixes recorded yet. Each time you accept a fix, Redpen notes which rule it was, so this page can show the mistakes that keep coming back."
        }
        var out = "This week: \(this.count) fix\(this.count == 1 ? "" : "es"). The week before: \(last.count).\n"
        let counts = Dictionary(grouping: this, by: \.lesson).mapValues(\.count).sorted { $0.value > $1.value }
        if counts.isEmpty { out += "\nNothing this week.\n" }
        for (id, n) in counts.prefix(5) {
            let before = last.filter { $0.lesson == id }.count
            let trend = before == 0 ? "new this week" : n < before ? "down from \(before)" : n > before ? "up from \(before)" : "same as last week"
            let title = this.first { $0.lesson == id }?.title ?? id
            out += "\n\(title.prefix(1).uppercased() + title.dropFirst()): \(n) time\(n == 1 ? "" : "s") (\(trend))\n"
            if let sample = this.last(where: { $0.lesson == id }) {
                out += "  You wrote \u{201C}\(sample.original)\u{201D}, fixed to \u{201C}\(sample.replacement)\u{201D}.\n"
            }
            if let l = Lessons.byID(id) {
                out += "  \(l.rule)\n"
                if !l.example.isEmpty { out += "  Example: \(l.example)\n" }
            }
        }
        let gone = Set(last.map(\.lesson)).subtracting(this.map(\.lesson))
        if !gone.isEmpty {
            let names = gone.compactMap { id in last.first { $0.lesson == id }?.title }.sorted()
            out += "\nDid not come back this week: \(names.joined(separator: ", ")).\n"
        }
        return out
    }
}
