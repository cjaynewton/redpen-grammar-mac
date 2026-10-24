import Foundation

/// How many words you wrote, by the hour, so "Your patterns" can count fixes per 1,000 words and a quiet week
/// doesn't look like progress. Only numbers are stored, never any text. It stays on this Mac.
public final class WordLog: @unchecked Sendable {
    public static let shared = WordLog(url: Private.folder.appendingPathComponent("words.json"))

    let url: URL
    private let lock = NSLock()
    private var pending: [Int: Int] = [:]   // hour (seconds since 1970 / 3600) to words, not yet saved
    private var saving: [Int: Int] = [:]    // being written now; still counted by `all()` until it is on disk
    /// Saves run one at a time, in order, off the main thread.
    private let queue = DispatchQueue(label: "redpen.wordlog.save", qos: .utility)

    public init(url: URL) { self.url = url }

    /// Adds words written at `date`. They are kept in memory until saved.
    public func add(_ words: Int, at date: Date = Date()) {
        guard words > 0 else { return }
        lock.withLock { pending[Self.hour(date), default: 0] += words }
    }

    /// Saves in the background. Saves queue up behind each other, so none is lost to another.
    public func saveSoon() { queue.async { self.save() } }

    /// Saves now and waits for any save already queued, for quitting.
    public func saveAndWait() { queue.sync { self.save() } }

    /// Writes what was added since the last save, merged with what other copies of Redpen saved, and drops
    /// anything older than `keepDays`. Nothing is lost if another copy saves at the same moment. Never waits more
    /// than about a second for another copy's lock; when it can't save, the counts stay in memory for next time.
    @discardableResult
    public func save(keepDays: Int = 90, now: Date = Date()) -> Bool {
        let oldest = Self.hour(now.addingTimeInterval(-Double(keepDays) * 86_400))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var held = false
        for _ in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { held = true; break }
            usleep(50_000)
        }
        guard held else { return false }
        defer { flock(fd, LOCK_UN) }
        // Holding this object's lock from the read to the write means `all()` sees each batch once: either
        // waiting in memory or saved on disk, never both and never neither.
        return lock.withLock {
            saving = pending
            pending = [:]
            var hours = read()
            for (h, n) in saving { hours[h, default: 0] += n }
            hours = hours.filter { $0.key >= oldest }
            let file = Dictionary(uniqueKeysWithValues: hours.map { (String($0.key), $0.value) })
            guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys]),
                  (try? data.write(to: url, options: .atomic)) != nil else {
                for (h, n) in saving { pending[h, default: 0] += n }
                saving = [:]
                return false
            }
            saving = [:]
            Private.lock(url)
            return true
        }
    }

    /// Every saved hour plus what is waiting to be saved, as (start of the hour, words).
    public func all() -> [(date: Date, words: Int)] {
        var hours: [Int: Int] = [:]
        lock.withLock {
            hours = read()
            for (h, n) in pending { hours[h, default: 0] += n }
            for (h, n) in saving { hours[h, default: 0] += n }
        }
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
/// new words; deleting alone counts nothing. A jump of more than `maxStep` words at once (a long paste, another
/// document opening in the same field) becomes the new starting point. The watcher counts growth only right
/// after a key press, so text an app adds by itself (a template, a quoted reply) isn't counted either.
public struct WordGrowth: Sendable {
    private var last: Int?
    public static let maxStep = 200

    public init() {}

    /// The words added since the last look, given the field's whole text now.
    public mutating func added(_ text: String) -> Int {
        let n = WordLog.count(text)
        defer { last = n }
        guard let last else { return 0 }
        let step = n - last
        return step > Self.maxStep ? 0 : max(0, step)
    }

    /// Starts again from the next text seen, for a new field.
    public mutating func reset() { last = nil }
}
