import Foundation
import FoundationModels
import NaturalLanguage

/// Commonly confused words. Grammar rules cannot tell "compliments" from "complements" without meaning, so
/// for each one found, Apple's model picks the word that fits the gap. It is asked twice with the options in
/// opposite order, and Redpen flags only when both answers agree on the other word. That cancels the model's
/// habit of picking whichever option it saw first.
public enum Confusables {
    static let groups: [[String]] = [
        ["compliment", "complement"], ["compliments", "complements"], ["complimented", "complemented"],
        ["complimentary", "complementary"], ["lead", "led"], ["principle", "principal"], ["principles", "principals"],
        ["accept", "except"], ["advice", "advise"], ["ensure", "insure", "assure"],
        ["ensured", "insured", "assured"], ["breath", "breathe"], ["stationary", "stationery"], ["discrete", "discreet"],
        ["council", "counsel"], ["elicit", "illicit"], ["precede", "proceed"], ["peak", "peek", "pique"],
        ["weather", "whether"], ["quite", "quiet"], ["choose", "chose"], ["personal", "personnel"],
        ["desert", "dessert"], ["loath", "loathe"], ["everyday", "every day"], ["maybe", "may be"],
    ]

    /// Short meanings so the small model can tell the words apart.
    static let gloss: [String: String] = [
        "compliment": "praise", "complement": "go well with, complete", "compliments": "praises",
        "complements": "goes well with, completes", "complimented": "praised", "complemented": "went well with",
        "complimentary": "free, or praising", "complementary": "going well together",
        "lead": "present tense of guide, or the metal", "led": "past tense of lead, guided",
        "principle": "a rule or belief", "principal": "main, or the head of a school",
        "principles": "rules or beliefs", "principals": "heads, or main people",
        "accept": "agree to, receive", "except": "other than", "advice": "a recommendation (noun)",
        "advise": "to recommend (verb)", "passed": "went by, or succeeded (verb)", "past": "earlier time, or beyond",
        "ensure": "make certain", "insure": "buy insurance for", "assure": "promise to someone",
        "ensured": "made certain", "insured": "covered by insurance", "assured": "promised someone",
        "breath": "air (noun)", "breathe": "take in air (verb)", "stationary": "not moving", "stationery": "paper and envelopes",
        "discrete": "separate", "discreet": "careful, private", "council": "a group that governs", "counsel": "advice, or a lawyer",
        "elicit": "draw out", "illicit": "illegal", "precede": "come before", "proceed": "go ahead",
        "peak": "the top", "peek": "a quick look", "pique": "stir interest", "weather": "rain or sun", "whether": "if",
        "quite": "very", "quiet": "not loud", "choose": "pick (present)", "chose": "picked (past)",
        "personal": "private, individual", "personnel": "staff", "desert": "dry land, or abandon", "dessert": "sweet course",
        "loath": "unwilling", "loathe": "hate", "everyday": "ordinary (adjective)", "every day": "each day",
        "maybe": "perhaps", "may be": "might be",
    ]

    static let lookup: [String: [String]] = {
        var m: [String: [String]] = [:]
        for g in groups { for w in g { m[w] = g } }
        return m
    }()

    struct Hit { let range: NSRange; let word: String; let options: [String] }

    static func hits(in text: String) -> [Hit] {
        let ns = text as NSString
        var out: [Hit] = []
        // Two-word forms first ("set up"), then single words.
        for (w, g) in lookup where w.contains(" ") {
            var r = ns.range(of: w, options: [.caseInsensitive])
            while r.location != NSNotFound {
                if isWholeWord(ns, r) { out.append(Hit(range: r, word: ns.substring(with: r), options: g)) }
                let next = NSMaxRange(r)
                r = ns.range(of: w, options: [.caseInsensitive], range: NSRange(location: next, length: ns.length - next))
            }
        }
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, wr, _, _ in
            guard let word, let g = lookup[word.lowercased()] else { return }
            let r = NSRange(wr, in: text)
            if out.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { return }
            out.append(Hit(range: r, word: word, options: g))
        }
        return out
    }

    static func isWholeWord(_ ns: NSString, _ r: NSRange) -> Bool {
        let letters = CharacterSet.letters
        if r.location > 0, let c = UnicodeScalar(ns.character(at: r.location - 1)), letters.contains(c) { return false }
        if NSMaxRange(r) < ns.length, let c = UnicodeScalar(ns.character(at: NSMaxRange(r))), letters.contains(c) { return false }
        return true
    }

    /// The sentence holding a range, with the range relative to it.
    static func sentence(in text: String, around r: NSRange) -> (String, NSRange) {
        var found = (text, r)
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, stop in
            let nr = NSRange(sr, in: text)
            if let s, NSLocationInRange(r.location, nr) {
                found = (s, NSRange(location: r.location - nr.location, length: r.length)); stop = true
            }
        }
        return found
    }

    /// Phrases where the word is right whatever the model thinks: "food desert", "the personnel are".
    static let locked = try! NSRegularExpression(pattern: "\\bfood deserts?\\b|\\bpersonnel (?:are|were|is|was|have|had|will|who|in|on|at|from)\\b|\\b(?:paid|key|military|medical|sales|support|security|team) personnel\\b", options: [.caseInsensitive])

    static func isLocked(_ text: String, _ r: NSRange) -> Bool {
        locked.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).contains { NSIntersectionRange($0.range, r).length > 0 }
    }

    @available(macOS 26, *)
    static func pick(_ sentence: String, gap: NSRange, options: [String]) async -> String? {
        let ns = sentence as NSString
        let blanked = ns.replacingCharacters(in: gap, with: "____")
        let session = LanguageModelSession(instructions: """
        Pick the word whose meaning fits the blank. First think about what the sentence is saying, then compare \
        the meaning of each option, then check grammar and tense. Reply with the word only.
        """)
        let shown = options.map { o in gloss[o].map { "\(o) (\($0))" } ?? o }
        let prompt = "Sentence: \(blanked)\nOptions: \(shown.joined(separator: " | "))\nReply with the word only."
        guard let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0)).content else { return nil }
        let answer = r.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return options.first { answer == $0 || answer.hasPrefix($0 + " ") }
    }

    static let compounds: [(String, String)] = [
        ("setup", "set up"), ("login", "log in"), ("backup", "back up"), ("checkout", "check out"), ("workout", "work out"),
        ("lineup", "line up"), ("signup", "sign up"), ("rollout", "roll out"), ("breakdown", "break down"),
        ("markup", "mark up"), ("pickup", "pick up"), ("shutdown", "shut down"), ("layout", "lay out"),
        ("buyout", "buy out"), ("startup", "start up"), ("handoff", "hand off"), ("walkthrough", "walk through"),
        ("followup", "follow up"), ("payout", "pay out"), ("cutoff", "cut off"), ("takeaway", "take away"),
    ]
    static let verbCue = "(?:to|will|would|can|could|should|must|might|may|please|let's|lets|I|we|you|they|don't|didn't|won't|can't|need to|have to)"
    static let nounCue = "(?:the|a|an|our|your|their|my|his|her|its|this|that|every|each|no|new|first|quick|full)"

    /// "setup" after "to"/"will"/a pronoun is a verb and should be two words; "set up" after "the"/"a" is a noun
    /// and should be one. Pure grammar, no model.
    static func compoundIssues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = []
        for (one, two) in compounds {
            let asVerb = try! NSRegularExpression(pattern: "\\b\(verbCue) (\(one))\\b", options: [.caseInsensitive])
            for m in asVerb.matches(in: text, range: full) {
                let r = m.range(at: 1)
                out.append(Issue(range: r, kind: .grammar, message: "As a verb this is two words: \u{201C}\(two)\u{201D}.",
                                 replacements: [two], original: ns.substring(with: r)))
            }
            let asNoun = try! NSRegularExpression(pattern: "\\b\(nounCue) (\(two))\\b(?! (?:the|a|an|our|your|their|my|his|her|its|this|that|it|them|him|us|me)\\b)", options: [.caseInsensitive])
            for m in asNoun.matches(in: text, range: full) {
                let r = m.range(at: 1)
                out.append(Issue(range: r, kind: .grammar, message: "As a noun this is one word: \u{201C}\(one)\u{201D}.",
                                 replacements: [one], original: ns.substring(with: r)))
            }
        }
        return out
    }

    /// "The brand past the review" has no verb, so "past" must be "passed". "Walked past" already has one.
    static func pastIssues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s else { return }
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = s
            var verbs = 0
            var pastRange: Range<String.Index>?
            tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, r in
                if s[r].lowercased() == "past" { pastRange = r } else if tag == .verb { verbs += 1 }
                return true
            }
            guard let pr = pastRange, verbs == 0 else { return }
            let nr = NSRange(pr, in: s)
            let abs = NSRange(location: NSRange(sr, in: text).location + nr.location, length: nr.length)
            let word = String(s[pr])
            out.append(Issue(range: abs, kind: .grammar, message: "This sentence needs a verb: \u{201C}passed\u{201D}.",
                             replacements: [word.first!.isUppercase ? "Passed" : "passed"], original: word))
        }
        return out
    }

    /// Ranges are relative to `text`.
    public static func check(_ text: String) async -> [Issue] {
        var out: [Issue] = compoundIssues(text) + pastIssues(text)
        guard #available(macOS 26, *), AppleModel.isAvailable else { return out }
        for h in hits(in: text) where !isLocked(text, h.range) {
            let (s, gap) = sentence(in: text, around: h.range)
            guard s.split(separator: " ").count >= 3 else { continue }
            guard let a = await pick(s, gap: gap, options: h.options),
                  let b = await pick(s, gap: gap, options: h.options.reversed()) else { continue }
            let current = h.word.lowercased()
            guard a == b, a != current else { continue }
            let rep = h.word.first?.isUppercase == true ? a.prefix(1).uppercased() + a.dropFirst() : a
            out.append(Issue(range: h.range, kind: .grammar, message: "Commonly confused: did you mean \u{201C}\(rep)\u{201D}?",
                             replacements: [rep], original: h.word))
        }
        return out
    }
}
