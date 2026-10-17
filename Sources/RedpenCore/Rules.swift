import Foundation
import NaturalLanguage

/// Grammar patterns the other engines miss, plus the optional house-style rules. Plain code, no model.
public enum Rules {
    static let dashes = try! NSRegularExpression(pattern: "\\s*(\u{2014}|\\s\u{2013}\\s|\\s--\\s)\\s*")
    // A colon joining two clauses. Labels ("Capital deployed: $400K"), times, URLs and lists are skipped below.
    static let colon = try! NSRegularExpression(pattern: "([A-Za-z\\)\"'])(:)\\s+([A-Za-z][^\\n]*)")
    public static func check(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) -> [Issue] {
        var out: [Issue] = patternIssues(text)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for m in style.noDashes ? dashes.matches(in: text, range: full) : [] {
            out.append(Issue(range: m.range, kind: .voice, message: "No em dashes. Use a period or a comma.",
                             replacements: [", ", ". "], original: ns.substring(with: m.range)))
        }

        for m in style.colonsOnlyForLabels ? colon.matches(in: text, range: full) : [] {
            let colonR = m.range(at: 2)
            let rest = ns.substring(with: m.range(at: 3))
            // Only the rest of this sentence counts: "qualification: five years. J-League ..." is a label.
            let after = rest.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? rest
            let lineStart = ns.lineRange(for: NSRange(location: colonR.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: colonR.location - lineStart))
            // Words since the sentence began: "The net result: ..." is a three-word label mid-paragraph.
            let before = line.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? line
            let beforeWords = before.split(whereSeparator: { $0 == " " }).count
            let afterWords = after.split(separator: " ").count
            // Labels are short and start the line; a literal list after a colon is fine.
            if beforeWords <= 4 { continue }
            if afterWords < 4 || after.contains(",") && after.split(separator: ",").count >= 3 { continue }
            // "two variables: income growth and fatalities" announces a list.
            if before.range(of: "\\b(two|three|four|five|six|several|\\d+) [a-z-]+s$", options: .regularExpression) != nil { continue }
            if before.hasSuffix("http") || before.hasSuffix("https") { continue }
            let first = String(after.prefix(1)).uppercased()
            let span = NSRange(location: colonR.location, length: m.range(at: 3).location + 1 - colonR.location)
            out.append(Issue(range: span, kind: .voice,
                             message: "Colon used as a connector. Make it a period.",
                             replacements: [". " + first], original: ns.substring(with: span)))
        }

        // Search the original text, ignoring case, so ranges stay right when lowercasing changes a string's length.
        for phrase in style.disclaimers where !phrase.isEmpty {
            var r = ns.range(of: phrase, options: .caseInsensitive)
            while r.location != NSNotFound {
                out.append(Issue(range: r, kind: .voice, message: "Disclaimer. Cut it and let the evidence speak.",
                                 replacements: [""], original: ns.substring(with: r)))
                let next = r.location + r.length
                r = ns.range(of: phrase, options: .caseInsensitive, range: NSRange(location: next, length: ns.length - next))
            }
        }

        if longform, !style.containerWords.isEmpty {
            let words = Set(style.containerWords.map { $0.lowercased() })
            text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, wr, _, _ in
                guard let word, words.contains(word.lowercased()) else { return }
                out.append(Issue(range: NSRange(wr, in: text), kind: .voice,
                                 message: "\"\(word)\" is a container word. Say the concrete thing.",
                                 replacements: [], original: word))
            }
        }

        out += StarterSet.issues(text, sets: style.starterSets,
                                 skip: longform ? ownWords(style) : [])

        if style.flagOtherLanguages { out += languageIssues(text) }
        return out
    }

    /// The own-list words the container-word check will flag. It matches single words only, so a phrase on the list
    /// leaves the starter sets to catch it.
    static func ownWords(_ style: HouseStyle) -> Set<String> {
        Set(style.containerWords.map { $0.lowercased() }.filter { !$0.contains(" ") })
    }

    // Grammar slips the small model lets through.
    static let meAnd = try! NSRegularExpression(pattern: "(?:^|(?<=[.!?]\\s))(Me and ([A-Z][a-z]+|(?:the|my|our|your|his|her|their) [a-z]+))\\b(?=\\s+[a-z]+(?:ed|s)?\\b)")
    static let eachHave = try! NSRegularExpression(pattern: "\\b(?:Each|Every one|Neither|Either) of (?:the |our |their |these |those )?\\w+ (have|are|were|do|don't)\\b", options: [.caseInsensitive])

    // Two full sentences joined by a comma: "The buyer called, she wants the samples."
    static let splice = try! NSRegularExpression(pattern: ", (I|you|he|she|it|we|they) (?!and\\b|but\\b|or\\b)[a-z']+")
    static let openers: Set<String> = ["if", "when", "while", "because", "although", "though", "since", "after", "before",
        "as", "unless", "until", "once", "whenever", "where", "wherever", "whether", "even", "in", "on", "at", "for",
        "with", "by", "during", "from", "to", "of", "over", "under", "without", "yes", "no", "well", "so", "now", "then",
        "however", "still", "also", "and", "but", "or", "honestly", "frankly", "first", "second", "finally", "today",
        "yesterday", "tomorrow", "here", "there", "please", "thanks", "ok", "okay", "sure", "oh", "hi", "hey", "dear"]

    static let timeWords: Set<String> = ["year", "years", "month", "months", "week", "weeks", "day", "days", "morning",
        "night", "season", "seasons", "decade", "decades", "spring", "summer", "fall", "autumn", "winter", "quarter", "time"]

    static func spliceIssues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s else { return }
            let sns = s as NSString
            let base = NSRange(sr, in: text).location
            for m in splice.matches(in: s, range: NSRange(location: 0, length: sns.length)) {
                // ", he argued," is an aside, not a second sentence.
                if NSMaxRange(m.range) < sns.length, sns.character(at: NSMaxRange(m.range)) == 44 { continue }
                let before = sns.substring(to: m.range.location)
                let words = before.split(whereSeparator: { $0 == " " }).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                // "The following year, they won": a time phrase introducing the sentence, not a second sentence.
                let timeIntro = words.count <= 4 && words.last.map { timeWords.contains($0) } == true
                guard words.count >= 3, let first = words.first, !openers.contains(first), !first.hasSuffix("ing"), !timeIntro,
                      !before.contains(",") else { continue }
                let pronoun = sns.substring(with: m.range(at: 1))
                let span = NSRange(location: base + m.range.location, length: 2 + (pronoun as NSString).length)
                let cap = pronoun == "I" ? "I" : pronoun.prefix(1).uppercased() + pronoun.dropFirst()
                out.append(Issue(range: span, kind: .grammar, message: "Two sentences joined by a comma. Make it a period.",
                                 replacements: [". " + cap], original: (text as NSString).substring(with: span)))
            }
        }
        return out
    }

    static func patternIssues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = spliceIssues(text) + Advanced.subjunctiveIssues(text) + Advanced.hyphenIssues(text)
        for m in meAnd.matches(in: text, range: full) {
            let raw = ns.substring(with: m.range(at: 2)); let name = raw.prefix(1).uppercased() + raw.dropFirst()
            out.append(Issue(range: m.range(at: 1), kind: .grammar, message: "Use \"\(name) and I\" as the subject",
                             replacements: ["\(name) and I"], original: ns.substring(with: m.range(at: 1))))
        }
        let singular = ["have": "has", "are": "is", "were": "was", "do": "does", "don't": "doesn't"]
        for m in eachHave.matches(in: text, range: full) {
            let v = ns.substring(with: m.range(at: 1))
            out.append(Issue(range: m.range(at: 1), kind: .grammar, message: "\"Each\" takes a singular verb",
                             replacements: [singular[v.lowercased()] ?? v], original: v))
        }
        return out
    }

    /// Flags sentences that came through in another language (voice typing can switch languages mid-sentence).
    static func languageIssues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, r, _, _ in
            guard let s, s.split(separator: " ").count >= 4 else { return }
            let rec = NLLanguageRecognizer()
            rec.languageConstraints = [.english, .spanish, .french, .portuguese, .italian, .german]
            rec.processString(s)
            guard let (lang, p) = rec.languageHypotheses(withMaximum: 1).first, lang != .english, p > 0.85 else { return }
            let name = Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsr = (text as NSString).range(of: trimmed, range: NSRange(r, in: text))
            out.append(Issue(range: nsr, kind: .voice, message: "This came through in \(name). Translate to English?",
                             replacements: [], original: trimmed))
        }
        return out
    }
}
