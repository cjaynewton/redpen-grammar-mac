import Foundation

/// Deep check's Replace: puts the revised text back exactly where the checked text was, and refuses whenever
/// that would be a guess. The checks live here, apart from Accessibility, so they can be tested.
public enum DeepReplace {
    public enum Spot: Equatable, Sendable {
        /// The checked text, unchanged, at this range of the field now.
        case at(NSRange)
        /// The checked text is no longer in the field: it was edited while Deep check ran.
        case changed
        /// The checked text appears more than once and has moved, so which one to replace would be a guess.
        case ambiguous
    }

    /// Where `original` sits in `current`: at its old range if it is still there, else its one and only copy
    /// (text typed above it moves it, without changing it). Anything else refuses.
    public static func locate(_ original: String, was range: NSRange, in current: String) -> Spot {
        let ns = current as NSString
        guard !original.isEmpty else { return .changed }
        if NSMaxRange(range) <= ns.length, ns.substring(with: range) == original { return .at(range) }
        let first = ns.range(of: original, options: .literal)
        guard first.location != NSNotFound else { return .changed }
        let after = NSMaxRange(first)
        let again = ns.range(of: original, options: .literal, range: NSRange(location: after, length: ns.length - after))
        return again.location == NSNotFound ? .at(first) : .ambiguous
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
