import Foundation

/// Ready-made word lists anyone can switch on in Settings, so nobody has to write their own list to get started.
/// Each entry maps a word or phrase to a shorter one, or to nil when the fix is to say the concrete thing instead.
public struct StarterSet: Sendable {
    public let id: String
    public let name: String
    public let blurb: String
    let message: String
    public let words: [(String, String?)]

    public var wordList: String { words.map(\.0).joined(separator: ", ") }

    public static let all: [StarterSet] = [plain, soundsLikeAI, hedging]

    public static let plain = StarterSet(
        id: "plain", name: "Plain English", blurb: "Filler with a shorter word underneath",
        message: "A shorter word says the same thing.",
        words: [("utilize", "use"), ("utilise", "use"), ("in order to", "to"), ("at this point in time", "now"),
                ("due to the fact that", "because"), ("in the event that", "if"), ("prior to", "before"),
                ("commence", "start"), ("facilitate", "help"), ("a number of", "some")])

    public static let soundsLikeAI = StarterSet(
        id: "ai", name: "Sounds like AI", blurb: "Words readers now link with machine writing",
        message: "Readers link this with machine writing. Say the concrete thing.",
        words: [("delve", nil), ("delves", nil), ("tapestry", nil), ("landscape", nil), ("leverage", nil),
                ("seamless", nil), ("seamlessly", nil), ("robust", nil), ("holistic", nil), ("synergy", nil),
                ("paradigm", nil), ("ecosystem", nil), ("it's worth noting", nil), ("in today's fast-paced world", nil)])

    public static let hedging = StarterSet(
        id: "hedging", name: "Hedging", blurb: "Softeners that make a point sound unsure",
        message: "A softener. The point reads stronger without it.",
        words: [("I think", nil), ("I feel like", nil), ("to be honest", nil), ("sort of", nil), ("kind of", nil),
                ("basically", nil)])

    /// Every match of the switched-on sets. Words already on the writer's own list are left to that rule.
    static func issues(_ text: String, sets ids: [String], skip own: Set<String>) -> [Issue] {
        let ns = text as NSString
        var out: [Issue] = []
        for set in all where ids.contains(set.id) {
            for (phrase, fix) in set.words where !own.contains(phrase.lowercased()) {
                // Whole words only, and either apostrophe, so "it’s worth noting" matches "it's worth noting".
                let body = NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "'", with: "['\u{2019}]")
                guard let re = try? NSRegularExpression(pattern: "\\b" + body + "\\b", options: .caseInsensitive) else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let found = ns.substring(with: m.range)
                    out.append(Issue(range: m.range, kind: .voice, message: set.message,
                                     replacements: fix.map { [matchCase($0, found)] } ?? [], original: found))
                }
            }
        }
        return out
    }

    /// "Utilize" becomes "Use" and "UTILIZE" becomes "USE", so the fix keeps the writer's capitals.
    static func matchCase(_ fix: String, _ found: String) -> String {
        guard let f = found.first, f.isUppercase else { return fix }
        if found.count > 1, found == found.uppercased() { return fix.uppercased() }
        return fix.prefix(1).uppercased() + fix.dropFirst()
    }
}
