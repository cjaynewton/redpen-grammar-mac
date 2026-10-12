import Foundation

/// Writes state changes to ~/Library/Logs/Redpen.log, only when the line differs from the last one.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Redpen.log")
    nonisolated(unsafe) static var last = ""
    static func note(_ s: String) {
        guard s != last else { return }
        last = s
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
