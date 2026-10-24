import Foundation

/// Deep check's Replace: puts the revised text back exactly where the checked text was, and refuses whenever
/// that would be a guess. The checks live here, apart from Accessibility, so they can be tested.
public enum DeepReplace {
    public enum Spot: Equatable, Sendable {
        /// The field reads exactly as it did when Deep check started, so the checked text is at this range.
        case at(NSRange)
        /// Something in the field changed while Deep check ran. Which text is which would be a guess.
        case changed
    }

    /// Where the checked text is now. Only when the whole field is exactly as it was when Deep check started:
    /// a match found anywhere else could be a copy of the paragraph, or another paragraph moved into its place.
    public static func locate(_ original: String, was range: NSRange, field before: String, in current: String) -> Spot {
        guard !original.isEmpty, current == before else { return .changed }
        let ns = current as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == original else { return .changed }
        return .at(range)
    }

    /// True when the text has a line reading REVISED, CHANGES or NOTES on its own. A reply can't be split
    /// safely then, so Replace isn't offered; Copy still is.
    public static func hasHeadingLine(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { ["REVISED", "CHANGES", "NOTES"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The range of `range` in `text` without the spaces and line breaks around it, so a replacement keeps the
    /// paragraph break and the indent that were there.
    public static func trimmed(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return range }
        let ws = CharacterSet.whitespacesAndNewlines
        var start = range.location, end = NSMaxRange(range)
        while start < end, let u = Unicode.Scalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = Unicode.Scalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The text under REVISED in a Deep check reply, or nil when the reply has none (an error, a refusal).
    /// REVISED, CHANGES and NOTES count only as headings on a line of their own.
    public static func revised(from reply: String) -> String? {
        let lines = reply.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "REVISED" }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { ["CHANGES", "NOTES"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? rest.endIndex
        let text = rest[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
