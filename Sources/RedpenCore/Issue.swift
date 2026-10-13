import Foundation

public enum IssueKind: String, Codable, Sendable {
    case spelling   // red
    case grammar    // blue
    case voice      // purple: house-style rules
}

public struct Issue: Sendable, Equatable {
    public var range: NSRange          // UTF-16 range in the full text
    public var kind: IssueKind
    public var message: String
    public var replacements: [String]  // empty means "flag only"
    public var original: String
    /// From Apple's language model: shown as a softer "maybe" underline, since it can misread good sentences.
    public var tentative = false

    public init(range: NSRange, kind: IssueKind, message: String, replacements: [String], original: String) {
        self.range = range
        self.kind = kind
        self.message = message
        self.replacements = replacements
        self.original = original
    }

    /// Stable key for "Ignore": the flagged words plus what is wrong, not the position.
    public var ignoreKey: String { "\(kind.rawValue)|\(original)|\(message)" }
}

extension NSRange {
    public func overlaps(_ other: NSRange) -> Bool { NSIntersectionRange(self, other).length > 0 }
    public func shifted(by offset: Int) -> NSRange { NSRange(location: location + offset, length: length) }
}
