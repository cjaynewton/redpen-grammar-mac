import Foundation

/// LanguageTool running on this Mac (brew services, port 8081). Thousands of hand-written grammar rules,
/// the closest open engine to Grammarly's. Text goes to localhost only.
public enum LanguageTool {
    static let url = URL(string: "http://127.0.0.1:8081/v2/check")!
    /// Rules that are noisy on real writing or duplicate Redpen's own checks.
    static let disabledRules = [
        "DASH_RULE", "EN_QUOTES", "WHITESPACE_RULE", "PUNCTUATION_PARAGRAPH_END", "ARROWS", "EN_UNPAIRED_QUOTES",
        "UPPERCASE_SENTENCE_START", "COMMA_PARENTHESIS_WHITESPACE", "DOUBLE_PUNCTUATION", "MULTIPLICATION_SIGN",
        "ENGLISH_WORD_REPEAT_BEGINNING_RULE", "EN_REPEATEDWORDS_PROBLEM",
    ]
    static let disabledCategories = ["TYPOGRAPHY", "STYLE", "REDUNDANCY", "CASING", "REPETITIONS_STYLE"]

    struct Response: Decodable {
        struct Match: Decodable {
            struct Replacement: Decodable { let value: String }
            struct Rule: Decodable { let id: String; let issueType: String? }
            let message: String
            let shortMessage: String?
            let offset: Int
            let length: Int
            let replacements: [Replacement]
            let rule: Rule
        }
        let matches: [Match]
    }

    /// True when the local LanguageTool server answers.
    public static func isRunning() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8081/v2/languages")!, timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
        return (r as? HTTPURLResponse)?.statusCode == 200
    }

    /// Ranges are relative to `text`. Returns [] if the server is not running.
    public static func check(_ text: String, language: String = "en-CA") async -> [Issue] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "text", value: text),
            .init(name: "language", value: language),
            .init(name: "level", value: "picky"),
            .init(name: "disabledRules", value: disabledRules.joined(separator: ",")),
            .init(name: "disabledCategories", value: disabledCategories.joined(separator: ",")),
        ]
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let res = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let ns = text as NSString
        return res.matches.compactMap { m in
            let r = NSRange(location: m.offset, length: m.length)
            guard NSMaxRange(r) <= ns.length, r.length > 0 else { return nil }
            // Only the dictionary rules are spelling. LanguageTool also tags confused words ("Your going") as
            // "misspelling", and those must survive the Mac-dictionary agreement check.
            let speller = m.rule.id.hasPrefix("MORFOLOGIK") || m.rule.id.contains("SPELLER") || m.rule.id.hasPrefix("HUNSPELL")
                || m.rule.id.hasPrefix("EN_MULTITOKEN_SPELLING")
            let kind: IssueKind = speller ? .spelling : .grammar
            let msg = (m.shortMessage?.isEmpty == false ? m.shortMessage! : m.message)
            return Issue(range: r, kind: kind, message: msg, replacements: Array(m.replacements.prefix(3).map(\.value)),
                         original: ns.substring(with: r))
        }
    }
}
