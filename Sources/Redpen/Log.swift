import Foundation
import RedpenCore

/// Writes state changes to ~/Library/Logs/Redpen.log, only when the line differs from the last one.
/// The log never holds your writing: app names, counts and positions only. Only your account can read it,
/// and it starts fresh past 1 MB.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Redpen.log")
    /// First line of every log written since the words were taken out. A log without it may hold flagged words,
    /// so it is cleared rather than kept.
    static let header = "Redpen log: no writing is kept here\n"
    static let cap = 1_000_000
    nonisolated(unsafe) static var last = ""
    nonisolated(unsafe) static var written = 0

    static func note(_ s: String) {
        guard s != last else { return }
        last = s
        // At the first line of each run, then every 1,000 lines, since Redpen can stay open for weeks.
        if written % 1_000 == 0 { startFreshIfNeeded() }
        written += 1
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { create(header + line) }
    }

    /// Clears a log from an older version, or one past the cap, and leaves it readable by this account only.
    private static func startFreshIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let first = (try? FileHandle(forReadingFrom: url)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: header.utf8.count) }
        if size > cap || first.map({ String(decoding: $0, as: UTF8.self) != header }) == true {
            try? FileManager.default.removeItem(at: url)
        }
        Private.lock(url)
    }

    private static func create(_ text: String) {
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}
