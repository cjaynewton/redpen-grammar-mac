import Foundation

public enum Engine {
    /// Instant layer: Mac spelling and grammar plus the hard rules. Ranges are relative to `text`.
    @MainActor
    public static func quick(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) -> [Issue] {
        outsideQuotes(merge(Spelling.check(text), Rules.check(text, longform: longform, style: style)), in: text)
    }

    /// Full check of one paragraph, including Apple's model and translations. Used by the test and by
    /// the app once typing pauses.
    @MainActor
    public static func full(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) async -> [Issue] {
        let lt = await LanguageTool.check(text)
        var issues = merge(spellingAgreed(Spelling.check(text), lt: lt),
                           protectNames(lt.filter { $0.kind != .spelling }, in: text))
        issues = merge(issues, Rules.check(text, longform: longform, style: style))
        issues = merge(issues, protectNames(await deep(text), in: text))
        return await fillTranslations(outsideQuotes(issues, in: text))
    }

    /// The slow, model-backed layer for one paragraph: confused words, then the rewrite-and-diff check.
    public static func deep(_ text: String) async -> [Issue] {
        merge(merge(await Confusables.check(text), await Advanced.dangling(text)), await AppleModel.check(text))
    }

    /// A word is misspelled only when the Mac dictionary flags it; LanguageTool's suggestions, when it agrees,
    /// go first because they rank better ("alot" -> "a lot", not "aloe"). Its solo spelling flags are dropped:
    /// it does not know trade words like "planogram".
    public static func spellingAgreed(_ mac: [Issue], lt: [Issue]) -> [Issue] {
        mac.map { m in
            guard m.kind == .spelling, let l = lt.first(where: { $0.kind == .spelling && $0.range == m.range }),
                  !l.replacements.isEmpty else { return m }
            var out = m
            out.replacements = Array((l.replacements + m.replacements).reduce(into: [String]()) { acc, r in
                if !acc.contains(r) { acc.append(r) } }.prefix(3))
            out.message = "Did you mean \u{201C}\(out.replacements[0])\u{201D}?"
            return out
        }
    }

    public static func fillTranslations(_ issues: [Issue]) async -> [Issue] {
        var out = issues
        for i in out.indices where out[i].kind == .voice && out[i].message.hasPrefix("This came through in") && out[i].replacements.isEmpty {
            if let t = await AppleModel.translate(out[i].original) { out[i].replacements = [t] }
        }
        return out
    }

    /// Keeps the earlier list's issue when two overlap, so spelling wins over a model guess on the same word.
    public static func merge(_ a: [Issue], _ b: [Issue]) -> [Issue] {
        var out = a
        for i in b where !out.contains(where: { $0.range.overlaps(i.range) }) { out.append(i) }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Paragraph around a cursor position, as (text, offset in full text).
    public static func paragraph(in text: String, at location: Int) -> (String, Int) {
        let ns = text as NSString
        let loc = max(0, min(location, ns.length))
        let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        return (ns.substring(with: r), r.location)
    }
}

// MARK: - Trust filters: keep checks off text the writer can't or shouldn't change

extension Engine {
    /// Ranges of text inside quotation marks ("..." or “...”). Quoted words are someone else's and stay as written.
    public static func quoteRanges(in text: String) -> [NSRange] {
        let re = try! NSRegularExpression(pattern: "\"[^\"\\n]+\"|\u{201C}[^\u{201D}\\n]+\u{201D}")
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    public static func outsideQuotes(_ issues: [Issue], in text: String) -> [Issue] {
        let quotes = quoteRanges(in: text)
        guard !quotes.isEmpty else { return issues }
        return issues.filter { i in !quotes.contains { NSIntersectionRange($0, i.range).length > 0 } }
    }

    /// Drops grammar suggestions from LanguageTool or the model that would change a name ("American Airlines" ->
    /// "America", "AdWords" -> "Google Ads"), or that read a singular name as plural ("The United States ... proves").
    /// Hand-written rules are not passed through here, so "Me and Sam" is still caught.
    @MainActor
    public static func protectNames(_ issues: [Issue], in text: String) -> [Issue] {
        let ns = text as NSString
        return issues.filter { i in
            guard i.kind == .grammar else { return true }
            if let r = i.message.range(of: "subject \u{2018}[A-Z][^\u{2019}]*\u{2019}", options: .regularExpression), !r.isEmpty {
                return false
            }
            var keep = true
            let words = i.original.split(whereSeparator: { $0 == " " || $0 == "," })
            var offset = i.range.location
            for w in words {
                let word = String(w)
                let loc = ns.range(of: word, range: NSRange(location: offset, length: NSMaxRange(i.range) - offset)).location
                if loc != NSNotFound { offset = loc + (word as NSString).length }
                guard word != "I", let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) else { continue }
                // Capitalised mid-sentence is a name. At the start of a sentence it is a name only when the
                // lowercase form is not a word ("American" yes, "Who's" and "Their" no).
                let midSentence = loc != NSNotFound && !Engine.startsSentence(at: loc, in: ns)
                if loc == NSNotFound || midSentence || !Spelling.isWord(word.lowercased()) {
                    keep = false; break
                }
            }
            return keep
        }
    }
}

extension Engine {
    static func startsSentence(at loc: Int, in ns: NSString) -> Bool {
        var i = loc - 1
        while i >= 0, let c = UnicodeScalar(ns.character(at: i)), CharacterSet.whitespaces.contains(c) { i -= 1 }
        guard i >= 0, let prev = UnicodeScalar(ns.character(at: i)) else { return true }
        return ".!?:\n\u{201C}\"(".unicodeScalars.contains(prev)
    }
}
