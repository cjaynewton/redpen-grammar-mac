import Foundation

public enum Engine {
    /// Instant layer: Mac spelling and grammar plus the hard rules. Ranges are relative to `text`.
    @MainActor
    public static func quick(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) -> [Issue] {
        merge(Spelling.check(text), Rules.check(text, longform: longform, style: style))
    }

    /// Full check of one paragraph, including Apple's model and translations. Used by the test and by
    /// the app once typing pauses.
    @MainActor
    public static func full(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) async -> [Issue] {
        var issues = merge(spellingAgreed(Spelling.check(text), lt: await LanguageTool.check(text)),
                           await LanguageTool.check(text).filter { $0.kind != .spelling })
        issues = merge(issues, Rules.check(text, longform: longform, style: style))
        issues = merge(issues, await deep(text))
        return await fillTranslations(issues)
    }

    /// The slow, model-backed layer for one paragraph: confused words, then the rewrite-and-diff check.
    public static func deep(_ text: String) async -> [Issue] {
        merge(await Confusables.check(text), await AppleModel.check(text))
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
