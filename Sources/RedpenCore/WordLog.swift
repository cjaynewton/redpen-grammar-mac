import Foundation

/// How many words you wrote, by the hour, so "Your patterns" can count fixes per 1,000 words and a quiet week
/// doesn't look like progress. Only numbers are stored, never any text. It stays on this Mac.
public final class WordLog: @unchecked Sendable {
    public static let shared = WordLog(url: Private.folder.appendingPathComponent("words.json"))

    let url: URL
    private let lock = NSLock()
    private var pending: [Int: Int] = [:]   // hour (seconds since 1970 / 3600) to words, not yet saved

    public init(url: URL) { self.url = url }

    /// Adds words written at `date`. They are kept in memory until `save()`.
    public func add(_ words: Int, at date: Date = Date()) {
        guard words > 0 else { return }
        lock.withLock { pending[Self.hour(date), default: 0] += words }
    }

    /// Writes what was added since the last save, merged with what other copies of Redpen saved, and drops
    /// anything older than `keepDays`. Nothing is lost if another copy saves at the same moment.
    public func save(keepDays: Int = 90, now: Date = Date()) {
        let add = lock.withLock { () -> [Int: Int] in defer { pending = [:] }; return pending }
        let oldest = Self.hour(now.addingTimeInterval(-Double(keepDays) * 86_400))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var held = flock(fd, LOCK_EX)
        while held != 0 && errno == EINTR { held = flock(fd, LOCK_EX) }
        guard held == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        var hours = read()
        for (h, n) in add { hours[h, default: 0] += n }
        hours = hours.filter { $0.key >= oldest }
        let file = Dictionary(uniqueKeysWithValues: hours.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        Private.lock(url)
    }

    /// Every saved hour plus what is waiting to be saved, as (start of the hour, words).
    public func all() -> [(date: Date, words: Int)] {
        var hours = read()
        lock.withLock { for (h, n) in pending { hours[h, default: 0] += n } }
        return hours.map { (Date(timeIntervalSince1970: Double($0.key) * 3600), $0.value) }
    }

    private func read() -> [Int: Int] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in file { if let h = Int(k), v > 0 { out[h] = v } }
        return out
    }

    static func hour(_ d: Date) -> Int { Int(floor(d.timeIntervalSince1970 / 3600)) }

    /// Words in a piece of text: runs of characters with at least one letter or digit.
    public static func count(_ text: String) -> Int {
        var n = 0, inWord = false
        for s in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(s) { inWord = false }
            else if !inWord, CharacterSet.alphanumerics.contains(s) { inWord = true; n += 1 }
        }
        return n
    }
}

/// Counts the words a writer adds to one field, from the moment Redpen starts reading it. Text already in the
/// field (an old document, a quoted reply) is the starting point, not counted. Deleting and retyping counts the
/// new words; deleting alone counts nothing.
public struct WordGrowth: Sendable {
    private var last: Int?

    public init() {}

    /// The words added since the last look, given the field's whole text now.
    public mutating func added(_ text: String) -> Int {
        let n = WordLog.count(text)
        defer { last = n }
        guard let last else { return 0 }
        return max(0, n - last)
    }

    /// Starts again from the next text seen, for a new field.
    public mutating func reset() { last = nil }
}
