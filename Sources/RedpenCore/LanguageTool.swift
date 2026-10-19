import Foundation

/// LanguageTool running on this Mac (brew services, port 8081). Thousands of hand-written grammar rules,
/// the closest open engine to Grammarly's. Text goes to this Mac only, and only to a LanguageTool this account runs.
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

    /// True when the server on port 8081 answers as LanguageTool (its language list must decode and include English)
    /// and the program listening there belongs to this Mac account. Any other program on the port, including one
    /// started by another login on the same Mac, gets no text from Redpen.
    public static func isRunning(fresh: Bool = false) async -> Bool {
        guard listenerIsMine(fresh: fresh) else { return false }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8081/v2/languages")!, timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (data, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return looksLikeLanguageTool(data)
    }

    nonisolated(unsafe) private static var owner: (at: Date, mine: Bool)?
    private static let ownerLock = NSLock()

    /// Asks lsof who is listening on 127.0.0.1:8081. lsof only sees this account's own programs, so a listener
    /// owned by anyone else shows up as nobody and fails. Status checks may reuse a yes for 30 seconds and a no
    /// for 2; anything about to send writing passes `fresh` and asks again, so an engine that quit and was
    /// replaced by another account's program is never trusted on an old answer.
    public static func listenerIsMine(fresh: Bool = false, now: Date = Date()) -> Bool {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if !fresh, let o = owner, now.timeIntervalSince(o.at) < (o.mine ? 30 : 2) { return o.mine }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP@127.0.0.1:8081", "-sTCP:LISTEN", "-Fu"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var mine = false
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            mine = ownerIsMe(String(decoding: data, as: UTF8.self))
        }
        owner = (now, mine)
        return mine
    }

    /// lsof's -F output names each listener's owner on a "u<uid>" line; every listener must be this account.
    public static func ownerIsMe(_ lsof: String, uid: uid_t = getuid()) -> Bool {
        let uids = lsof.split(separator: "\n").filter { $0.hasPrefix("u") }.map { String($0.dropFirst()) }
        return !uids.isEmpty && uids.allSatisfy { $0 == String(uid) }
    }

    /// LanguageTool's /v2/languages answer: a list of languages that includes English.
    public static func looksLikeLanguageTool(_ data: Data) -> Bool {
        guard let langs = try? JSONDecoder().decode([Language].self, from: data) else { return false }
        return langs.contains { $0.longCode.hasPrefix("en") }
    }

    struct Language: Decodable { let longCode: String }


    /// Ranges are relative to `text`. Returns [] if the server is not running.
    public static func check(_ text: String, language: String = "en-CA") async -> [Issue] {
        await checkIfReady(text, language: language) ?? []
    }

    /// Like `check`, but nil when no answer came back (server down, not LanguageTool, or timed out), so the caller
    /// can try the same text again later instead of treating it as clean.
    public static func checkIfReady(_ text: String, language: String = "en-CA") async -> [Issue]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // Ask the port to prove it is LanguageTool before every check: the program behind it can change at any time.
        guard await isRunning(fresh: true) else { return nil }
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
