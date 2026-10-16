import Foundation

/// LanguageTool running on this Mac (brew services, port 8081). Thousands of hand-written grammar rules,
/// the closest open engine to Grammarly's. Text goes to localhost only.
public enum LanguageTool {
    static let url = URL(string: "http://127.0.0.1:8081/v2/check")!
    /// Rules that are noisy on real writing or duplicate Redpen's own checks.
    static let disabledRules = [
        "DASH_RULE", "EN_QUOTES", "WHITESPACE_RULE", "PUNCTUATION_PARAGRAPH_END", "ARROWS", "EN_UNPAIRED_QUOTES",
        "UPPERCASE_SENTENCE_START", "COMMA_PARENTHESIS_WHITESPACE", "DOUBLE_PUNCTUATION", "MULTIPLICATION_SIGN",
        "ENGLISH_WORD_REPEAT_BEGINNING_RULE", "EN_REPEATEDWORDS_PROBLEM", "COMMA_COMPOUND_SENTENCE",
        "COMMA_COMPOUND_SENTENCE_2",
    ]
    static let disabledCategories = ["TYPOGRAPHY", "STYLE", "REDUNDANCY", "CASING", "REPETITIONS_STYLE", "PROPER_NOUNS"]

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

    /// True when the server on port 8081 answers as LanguageTool: its language list must decode and include English.
    /// Any other program that happens to use the port gets no text from Redpen.
    public static func isRunning() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8081/v2/languages")!, timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (data, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200
        else { trust.set(false); return false }
        let ok = looksLikeLanguageTool(data)
        trust.set(ok)
        return ok
    }

    /// LanguageTool's /v2/languages answer: a list of languages that includes English.
    public static func looksLikeLanguageTool(_ data: Data) -> Bool {
        guard let langs = try? JSONDecoder().decode([Language].self, from: data) else { return false }
        return langs.contains { $0.longCode.hasPrefix("en") }
    }

    struct Language: Decodable { let longCode: String }

    /// Whether port 8081 was last seen to be LanguageTool, and when it was last asked.
    final class Trust: @unchecked Sendable {
        private let lock = NSLock()
        private var ok = false, askedAt = Date.distantPast
        func set(_ v: Bool) { lock.withLock { ok = v; askedAt = Date() } }
        var value: Bool { lock.withLock { ok } }
        var stale: Bool { lock.withLock { Date().timeIntervalSince(askedAt) > 10 } }
    }
    static let trust = Trust()

    /// Ranges are relative to `text`. Returns [] if the server is not running.
    public static func check(_ text: String, language: String = "en-CA") async -> [Issue] {
        await checkIfReady(text, language: language) ?? []
    }

    /// Like `check`, but nil when no answer came back (server down, not LanguageTool, or timed out), so the caller
    /// can try the same text again later instead of treating it as clean.
    public static func checkIfReady(_ text: String, language: String = "en-CA") async -> [Issue]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if !trust.value || trust.stale { guard await isRunning() else { return nil } }
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
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return parse(data, text: text)
    }

    /// Turns a /v2/check answer into issues, dropping any match whose range doesn't fit `text`. Nil if it doesn't decode.
    public static func parse(_ data: Data, text: String) -> [Issue]? {
        guard let res = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let ns = text as NSString
        return res.matches.compactMap { m in
            guard m.offset >= 0, m.length > 0, m.offset <= ns.length - m.length else { return nil }
            let r = NSRange(location: m.offset, length: m.length)
            // "protege" and "protégé" are both correct English; accents are optional.
            if m.rule.id.hasPrefix("EN_DIACRITICS") { return nil }
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
