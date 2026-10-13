import Foundation
import NaturalLanguage

/// Rules a careful editor marks that the other engines miss: the subjunctive ("If I were"),
/// hyphens in compound modifiers ("a two-year contract") and dangling modifiers.
public enum Advanced {

    // MARK: Subjunctive

    static let subject = "(I|he|she|it|this|that|there|(?:the|my|our|your|his|her|their|its|this|that|our) [a-z]+(?: [a-z]+)?|[A-Z][a-z]+)"
    // "If I was the buyer, I would ...": only when the sentence goes on to say what would happen.
    static let ifWas = try! NSRegularExpression(pattern: "\\b[Ii]f \(subject) (was)\\b(?=[^.!?]*\\b(?:would|could|might)\\b)")
    static let wishWas = try! NSRegularExpression(pattern: "\\b(?:wish|wishes|wished) (?:that )?\(subject) (was)\\b")
    // "The contract requires that every supplier sign": the verb after these takes its plain form.
    static let mandative = try! NSRegularExpression(pattern:
        "\\b(?:require|requires|required|demand|demands|demanded|request|requests|requested|recommend|recommends|recommended|propose|proposes|proposed|ask|asks|asked|(?:important|essential|vital|crucial|necessary|imperative)) that ([^,.;!?]{2,60})")

    static func subjunctiveIssues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = []
        for m in ifWas.matches(in: text, range: full) + wishWas.matches(in: text, range: full) {
            let r = m.range(at: 2)
            out.append(Issue(range: r, kind: .grammar,
                             message: "For something that isn't true, use \u{201C}were\u{201D}: \u{201C}if I were\u{201D}, \u{201C}I wish it were\u{201D}.",
                             replacements: ["were"], original: ns.substring(with: r)))
        }
        for m in mandative.matches(in: text, range: full) {
            let clause = ns.substring(with: m.range(at: 1))
            guard let (verbRange, plain) = presentVerb(in: clause) else { continue }
            let r = NSRange(location: m.range(at: 1).location + verbRange.location, length: verbRange.length)
            out.append(Issue(range: r, kind: .grammar,
                             message: "After \u{201C}requires that\u{201D} and similar, use the plain verb: \u{201C}\(plain)\u{201D}.",
                             replacements: [plain], original: ns.substring(with: r)))
        }
        return out
    }

    /// The first verb in a short clause, when it is a present-tense "-s" form, with its plain form.
    static func presentVerb(in clause: String) -> (NSRange, String)? {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = clause
        var found: (NSRange, String)?
        var words = 0
        tagger.enumerateTags(in: clause.startIndex..<clause.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            words += 1
            if words > 6 { return false }
            guard tag == .verb else { return true }
            let w = String(clause[r])
            let lw = w.lowercased()
            // Modals and past tense are not the error ("requires that he will", "asked that he was").
            if ["is"].contains(lw) { found = (NSRange(r, in: clause), "be") }
            else if lw == "has" { found = (NSRange(r, in: clause), "have") }
            else if lw.hasSuffix("s"), !lw.hasSuffix("ss"), words >= 2,
                    let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased(),
                    lemma != lw, lw == lemma + "s" || lw == lemma + "es" {
                found = (NSRange(r, in: clause), lemma)
            }
            return false
        }
        return found
    }

    // MARK: Compound modifiers

    static let numbers = "(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|ninety|hundred|\\d+)"
    static let units = "(?:year|month|week|day|hour|minute|second|mile|foot|pound|ounce|inch|metre|meter|litre|liter|gallon|kilometre|kilometer|dollar)"
    static let numberUnit = try! NSRegularExpression(pattern: "\\b(?:(?:[Aa]n?|[Tt]he|[Oo]ur|[Tt]heir|[Hh]is|[Hh]er|[Mm]y) one|\(numbers)) \(units)\\b(?= [a-z])")
    static let fixed = ["high quality", "low quality", "high end", "low end", "last minute", "long term", "short term",
                        "long range", "full time", "part time", "real time", "one time", "hands on", "up to date",
                        "state of the art", "face to face", "first come first served", "fast growing", "fast moving",
                        "high margin", "low margin", "high volume", "low cost", "high level", "large scale",
                        "small scale", "long standing", "open ended", "short lived", "long lasting", "low key"]
    static let fixedRegex = try! NSRegularExpression(pattern: "\\b(?:" + fixed.joined(separator: "|") + ")\\b(?= [a-z])", options: [.caseInsensitive])
    static let wellAdj = try! NSRegularExpression(pattern: "\\b(?:[Aa]n?|[Tt]he|[Oo]ur|[Tt]heir|[Hh]is|[Hh]er|[Mm]y|[Ii]ts|[Tt]his|[Tt]hat) (well (?:known|made|run|kept|built|paid|read|done|written|[a-z]+ed))\\b(?= [a-z])")

    static func hyphenIssues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [NSRange] = []
        for m in numberUnit.matches(in: text, range: full) {
            // "a one year contract": hyphenate only the number and unit, not the article.
            let s = ns.substring(with: m.range)
            let parts = s.split(separator: " ")
            let drop = parts.count == 3 ? parts[0].count + 1 : 0
            spans.append(NSRange(location: m.range.location + drop, length: m.range.length - drop))
        }
        for m in fixedRegex.matches(in: text, range: full) { spans.append(m.range) }
        for m in wellAdj.matches(in: text, range: full) { spans.append(m.range(at: 1)) }
        var out: [Issue] = []
        for r in spans where nounFollows(text, after: NSMaxRange(r)) {
            let phrase = ns.substring(with: r)
            let joined = phrase.replacingOccurrences(of: " ", with: "-")
            out.append(Issue(range: r, kind: .grammar,
                             message: "Words that describe a noun together take a hyphen: \u{201C}\(joined)\u{201D}.",
                             replacements: [joined], original: phrase))
        }
        return out
    }

    /// Whether the next word is a noun ("a two year contract"), not "ago", "later" or a verb.
    static func nounFollows(_ text: String, after loc: Int) -> Bool {
        let ns = text as NSString
        guard loc < ns.length else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        guard let idx = Range(NSRange(location: min(loc + 1, ns.length - 1), length: 0), in: text)?.lowerBound else { return false }
        let (tag, r) = tagger.tag(at: idx, unit: .word, scheme: .lexicalClass)
        let w = String(text[r]).lowercased()
        if ["old", "ago", "later", "earlier", "of", "and", "or", "in", "on", "at", "for", "to"].contains(w) { return false }
        return tag == .noun
    }

    // MARK: Dangling modifiers

    /// A sentence that opens with an action ("Walking into the store,") and whose main clause starts with
    /// something that could not have done it ("the shelves"). The opener and that subject; the model decides.
    public struct Opener: Sendable { public let range: NSRange; public let phrase: String; public let subject: String }

    static let ingOpener = try! NSRegularExpression(pattern: "^((?:(?:After|Before|While|When|Since|Upon|On|By|Without) )?([A-Z]?[a-z]+ing)\\b[^,;:]{0,90}), (.+)$")
    static let havingOpener = try! NSRegularExpression(pattern: "^(Having [^,;:]{1,90}), (.+)$")
    static let toOpener = try! NSRegularExpression(pattern: "^(To ([a-z]+)\\b[^,;:]{0,80}), (.+)$")
    static let exempt: Set<String> = ["generally", "speaking", "considering", "assuming", "given", "including", "excluding",
        "following", "regarding", "concerning", "judging", "barring", "pending", "starting", "beginning", "depending",
        "according", "notwithstanding", "turning", "putting", "during", "nothing", "something", "everything", "anything",
        "morning", "evening", "spring", "thing", "king", "being", "according", "counting", "allowing", "admitting",
        "granting", "supposing", "providing", "seeing", "talking", "moving"]
    static let toExempt: Set<String> = ["be", "put", "date", "that", "this", "sum", "summarize", "recap", "start", "begin",
        "say", "me", "my", "his", "her", "our", "their", "the", "a", "an"]
    static let people: Set<String> = ["i", "we", "you", "he", "she", "they", "someone", "somebody", "everyone", "everybody",
        "nobody", "people", "one", "it", "there", "this", "that", "these", "those", "what", "who", "each", "both", "all", "most", "many", "some"]

    public static func danglingOpeners(_ text: String) -> [Opener] {
        var out: [Opener] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let sns = trimmed as NSString
            let all = NSRange(location: 0, length: sns.length)
            var phraseR: NSRange?, rest = ""
            if let m = ingOpener.firstMatch(in: trimmed, range: all) {
                let ing = sns.substring(with: m.range(at: 2)).lowercased()
                guard !exempt.contains(ing), isVerb(sns.substring(with: m.range(at: 2)), in: trimmed) else { return }
                phraseR = m.range(at: 1); rest = sns.substring(with: m.range(at: 3))
            } else if let m = havingOpener.firstMatch(in: trimmed, range: all) {
                phraseR = m.range(at: 1); rest = sns.substring(with: m.range(at: 2))
            } else if let m = toOpener.firstMatch(in: trimmed, range: all) {
                let verb = sns.substring(with: m.range(at: 2))
                guard !toExempt.contains(verb), isVerb(verb, in: trimmed) else { return }
                phraseR = m.range(at: 1); rest = sns.substring(with: m.range(at: 3))
            }
            guard let pr = phraseR, let subj = subjectPhrase(rest) else { return }
            let lead = (s as NSString).range(of: trimmed).location
            let base = NSRange(sr, in: text).location + lead
            out.append(Opener(range: pr.shifted(by: base), phrase: sns.substring(with: pr), subject: subj))
        }
        return out
    }

    static func isVerb(_ word: String, in sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        guard let r = sentence.range(of: word) else { return false }
        return tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0 == .verb
    }

    /// The noun phrase before the main verb ("the shelves were empty" -> "the shelves"), or nil when the
    /// subject is a person, a pronoun or a name, which can do the opener's action.
    static func subjectPhrase(_ clause: String) -> String? {
        guard let first = clause.split(separator: " ").first.map(String.init) else { return nil }
        let bare = first.trimmingCharacters(in: .punctuationCharacters)
        if people.contains(bare.lowercased()) { return nil }
        if bare.first?.isUppercase == true { return nil }  // a name or a company
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = clause
        var words: [String] = []
        var stop = false
        tagger.enumerateTags(in: clause.startIndex..<clause.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if tag == .verb || words.count >= 5 { stop = words.count >= 5; return false }
            words.append(String(clause[r]))
            return true
        }
        guard !stop, !words.isEmpty, words.count <= 4 else { return nil }
        if words.contains(where: { $0.first?.isUppercase == true || people.contains($0.lowercased()) && $0 != words.first }) { return nil }
        return words.joined(separator: " ")
    }

    /// Dangling modifiers, confirmed by Apple's model. Shown as "maybe": the model judges what the subject is.
    public static func dangling(_ text: String) async -> [Issue] {
        var out: [Issue] = []
        for o in danglingOpeners(text) where await AppleModel.cannotDo(o.subject, o.phrase) {
            out.append({
                var i = Issue(range: o.range, kind: .grammar,
                              message: "Dangling modifier: \u{201C}\(o.subject)\u{201D} didn't do this. Put whoever did it right after the comma.",
                              replacements: [], original: o.phrase)
                i.tentative = true
                return i
            }())
        }
        return out
    }
}
