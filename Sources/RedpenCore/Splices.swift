import Foundation
import NaturalLanguage

/// Two full sentences joined by a comma alone ("The supplier called twice, I will ring back") or by nothing
/// ("The red bowls are sold out we still have blue ones"). Each side must have its own subject and verb; lists,
/// asides, dialogue, questions and clauses joined by a conjunction are left alone. Plain code, no model.
enum Splices {
    struct Token {
        let text: String
        let lower: String
        let tag: NLTag?
        let lemma: String
        let range: NSRange  // relative to the sentence
    }

    enum SubjectKind { case pronoun, noun, name, imperative }
    struct Subject { let end: Int; let kind: SubjectKind; let plural: Bool }

    static let pronouns: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "this", "that", "these", "those",
        "there", "everyone", "everybody", "someone", "somebody", "nobody", "everything", "something", "nothing"]
    static let personal: Set<String> = ["i", "we", "you", "they", "he", "she"]
    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "our", "your", "his",
        "her", "their", "its", "no", "every", "each", "some", "any", "all", "both", "several", "many", "most", "few", "another"]
    static let auxiliaries: Set<String> = ["is", "are", "was", "were", "am", "has", "have", "had", "do", "does", "did",
        "will", "would", "can", "could", "should", "shall", "must", "may", "might", "cannot", "ca", "wo", "'s", "'re",
        "'m", "'ve", "'ll", "'d",
        "\u{2019}s", "\u{2019}re", "\u{2019}m", "\u{2019}ve", "\u{2019}ll", "\u{2019}d"]
    static let beForms: Set<String> = ["is", "are", "was", "were", "am", "'s", "'re", "'m", "\u{2019}s", "\u{2019}re", "\u{2019}m"]
    /// Verbs of saying and thinking: ", he said" is a dialogue tag and ", I think" an aside.
    static let reporting: Set<String> = ["said", "says", "say", "asked", "asks", "replied", "added", "wrote", "told",
        "noted", "explained", "argued", "continued", "insisted", "warned", "recalled", "admitted", "agreed", "answered",
        "shouted", "whispered", "suggested", "observed", "remarked", "claimed", "concluded", "confirmed", "think",
        "thought", "believe", "guess", "mean", "suppose", "hope", "know", "bet", "assume", "reckon", "expect", "feel",
        "fear", "figure", "imagine", "trust", "wonder", "understand", "see", "realise", "realize", "promise", "swear"]
    /// Words that open a dependent clause; a clause starting with one is not a sentence on its own.
    static let subordinators: Set<String> = ["if", "when", "while", "because", "although", "though", "since", "after",
        "before", "as", "unless", "until", "till", "once", "whenever", "where", "wherever", "whereas", "whether", "even",
        "than", "that", "which", "who", "whom", "whose", "what", "why", "how", "whatever", "whoever", "however",
        "provided", "given", "supposing", "assuming", "considering", "despite", "unlike", "like", "except", "lest",
        "so", "such", "too", "else", "otherwise"]
    /// A second clause starting with one of these is joined, not spliced: "we shipped, but the buyer waited",
    /// "we sold 400 units, then sales stalled".
    static let joiners: Set<String> = ["and", "but", "or", "nor", "so", "yet", "for", "then", "also", "however",
        "therefore", "otherwise", "instead", "meanwhile", "still", "thus", "hence", "anyway", "besides", "nonetheless",
        "nevertheless", "moreover", "furthermore", "consequently", "afterwards", "later", "next", "first", "second",
        "finally", "now", "not", "no", "yes", "which", "who", "whom", "whose", "especially", "particularly", "mostly",
        "mainly", "only", "just", "even", "perhaps", "maybe", "probably", "possibly", "apparently", "hopefully"]
    /// "It is clear the buyer needs more time": these take a clause with no "that", so no sentence ends with them.
    static let takeClause: Set<String> = ["clear", "obvious", "likely", "unlikely", "possible", "impossible", "certain",
        "sure", "confident", "glad", "sorry", "aware", "afraid", "happy", "true", "evident", "apparent", "important",
        "essential", "vital", "crucial", "necessary", "lucky", "surprised", "worried", "convinced", "hopeful", "doubtful",
        "probable", "surprising", "odd", "strange", "funny", "ironic", "natural", "inevitable", "fortunate", "unfortunate",
        "remarkable", "notable", "told", "informed", "assured", "reminded", "warned", "pleased", "delighted", "concerned",
        "satisfied", "disappointed", "amazed", "shocked", "relieved", "determined", "thrilled", "excited", "upset",
        "annoyed", "grateful", "thankful", "scared", "proud", "embarrassed", "ashamed", "frustrated", "positive",
        "adamant", "insistent", "unaware", "mindful", "conscious", "optimistic", "pessimistic", "sad", "angry",
        "furious", "anxious", "nervous", "plain", "reported", "believed", "thought", "expected", "assumed", "estimated",
        "understood", "known", "rumoured", "rumored", "alleged", "claimed", "stated", "noted", "agreed", "decided",
        "suggested", "recommended", "hoped", "feared", "felt", "found", "acknowledged", "accepted", "established",
        "confirmed", "argued", "proposed", "announced", "assumed", "guaranteed", "promised", "insisted", "doubted"]
    /// Words a fused sentence can run over without a comma but the writer meant as one sentence: "the sooner we ship",
    /// "it was a week ago we met", "a secret only we share".
    static let notBreaks: Set<String> = ["so", "too", "as", "very", "more", "less", "most", "least", "better", "worse",
        "rather", "sooner", "further", "farther", "longer", "enough", "ago", "else", "only", "just", "even", "almost",
        "nearly", "exactly", "precisely", "anywhere", "everywhere", "somewhere", "nowhere", "anytime", "much", "far",
        "quite", "pretty", "fairly", "half", "all", "both", "right", "well", "long", "same", "own", "such", "whole",
        "next", "last", "first", "other", "much", "many", "enough", "like", "alike", "together", "apart", "aside",
        "yet", "ever", "never", "always", "often", "sometimes", "usually", "already", "soon", "then", "than"]
    static let timeWords: Set<String> = ["today", "yesterday", "tomorrow", "tonight", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday"]
    static let particles: Set<String> = ["out", "up", "off", "away", "back", "down", "over", "through"]

    static func tokens(_ s: String) -> [Token] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = s
        var out: [Token] = []
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, r in
            let text = String(s[r])
            let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased() ?? text.lowercased()
            out.append(Token(text: text, lower: text.lowercased(), tag: tag, lemma: lemma, range: NSRange(r, in: s)))
            return true
        }
        return out
    }

    static func issues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s, !s.hasSuffix("?"), !s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return }
            // Quoted speech, lists after a colon and bracketed asides have their own grammar; stay out.
            if s.contains(where: { "\"\u{201C}\u{201D};:()[]\u{2014}\u{2013}".contains($0) }) || s.contains(" - ") { return }
            let toks = tokens(s)
            guard toks.count >= 5 else { return }
            let base = NSRange(sr, in: text).location
            if let i = commaSplice(toks) ?? fused(toks) {
                let (last, next, comma) = i
                let span = NSRange(location: last.range.location, length: NSMaxRange(next.range) - last.range.location)
                let cap = next.lower == "i" ? "I" : next.text.prefix(1).uppercased() + next.text.dropFirst()
                let msg = comma ? "Two sentences joined by a comma. Make it a period." : "Two sentences run together. Put a period between them."
                var reps = ["\(last.text). \(cap)"]
                if comma { reps.append("\(last.text); \(next.text)") }
                out.append(Issue(range: span.shifted(by: base), kind: .grammar, message: msg, replacements: reps,
                                 original: (text as NSString).substring(with: span.shifted(by: base))))
            }
        }
        return out
    }

    /// The last word before a splicing comma and the first word after it, or nil.
    static func commaSplice(_ toks: [Token]) -> (Token, Token, Bool)? {
        let commas = toks.indices.filter { toks[$0].text == "," }
        // "we stock bowls, our supplier makes them, and they sell well" is a series, not a splice.
        if commas.contains(where: { $0 + 1 < toks.count && ["and", "but", "or", "nor", "yet", "so"].contains(toks[$0 + 1].lower) }) { return nil }
        for (n, c) in commas.enumerated() where c >= 2 && c + 2 < toks.count {
            let left = Array(toks[0..<c])
            let end = n + 1 < commas.count ? commas[n + 1] : toks.count
            let right = Array(toks[(c + 1)..<end]).filter { $0.tag != .sentenceTerminator }
            // ", I think," and ", he argued," are asides.
            if n + 1 < commas.count, right.count <= 3 { continue }
            guard isSentence(left, allowPhrase: true), startsSentence(right, afterComma: true) != nil else { continue }
            return (left[left.count - 1], right[0], true)
        }
        return nil
    }

    /// Two sentences with nothing between them. Only a clear case: the first ends on an adverb, an adjective, a
    /// time word or a particle, and the second starts with a pronoun, a name, "please" or "the ...".
    static func fused(_ toks: [Token]) -> (Token, Token, Bool)? {
        if toks.contains(where: { $0.text == "," }) { return nil }
        for i in 2..<(toks.count - 2) {
            let t = toks[i], prev = toks[i - 1]
            let timeWord = timeWords.contains(t.lower)
            let describing = (t.tag == .adverb || t.tag == .adjective) && !notBreaks.contains(t.lower) && !takeClause.contains(t.lower)
                && !subordinators.contains(t.lower) && !joiners.contains(t.lower) && !t.lower.hasSuffix("er") && !t.lower.hasSuffix("ly")
            let participle = t.tag == .verb && t.lower.hasSuffix("ed") && beForms.contains(prev.lower)
                && !takeClause.contains(t.lower) && !reporting.contains(t.lower)
            let particle = particles.contains(t.lower) && prev.tag == .verb
            guard timeWord || describing || participle || particle else { continue }
            // "it was so fast we could not keep up", "the sooner we ship": one sentence after all.
            if ["so", "too", "as", "such", "the", "how", "that", "very"].contains(prev.lower) { continue }
            let left = Array(toks[0...(particle ? i - 1 : i)])
            if left.contains(where: { ["so", "such", "too", "that", "as"].contains($0.lower) }) { continue }
            guard isSentence(left, allowPhrase: true) else { continue }
            // "It was yesterday we met": a cleft, not two sentences.
            if left[0].lower == "it", left.count <= 4, left.contains(where: { beForms.contains($0.lower) }) { continue }
            let right = Array(toks[(i + 1)...]).filter { $0.tag != .sentenceTerminator }
            guard right.count >= 2, let kind = startsSentence(right, afterComma: false) else { continue }
            if kind == .pronoun, !personal.contains(right[0].lower) { continue }
            if kind == .imperative, ![.noun, .adjective, .adverb].contains(prev.tag) && !timeWord { continue }
            return (t, right[0], false)
        }
        return nil
    }

    /// Whether these words form a sentence of their own: a subject, then a finite verb, not opened by "if" or
    /// "because", and not trailing off on "is", "that" or "said".
    static func isSentence(_ toks: [Token], allowPhrase: Bool) -> Bool {
        guard toks.count >= 2, let last = toks.last else { return false }
        if [.preposition, .conjunction, .determiner].contains(last.tag) || beForms.contains(last.lower)
            || reporting.contains(last.lower) || ["that", "which", "to", "and", "or", "but", "not"].contains(last.lower) { return false }
        var i = 0
        while i < toks.count - 1, toks[i].tag == .adverb || toks[i].tag == .interjection, !subordinators.contains(toks[i].lower) { i += 1 }
        let first = toks[i]
        if subordinators.contains(first.lower) || [.preposition, .conjunction, .verb, .particle].contains(first.tag)
            || first.lower == "to" || first.lower == "not" { return false }
        guard let subj = subject(toks, at: i, sentenceStart: i == 0) else { return false }
        var j = subj.end
        if j < toks.count, toks[j].tag == .adverb { j += 1 }
        // "The first batch of cherry jam has arrived": one short phrase may sit between subject and verb.
        if allowPhrase, j < toks.count, ["of", "in", "for", "with", "from", "on", "at", "by"].contains(toks[j].lower) {
            var k = j + 1, n = 0
            while k < toks.count, n < 4, [.determiner, .adjective, .noun, .number, .adverb].contains(toks[k].tag) { k += 1; n += 1 }
            if k < toks.count, toks[k].tag == .verb || auxiliaries.contains(toks[k].lower) { j = k }
            if j < toks.count, toks[j].tag == .adverb { j += 1 }
        }
        guard j < toks.count else { return false }
        return finiteVerb(toks[j], after: subj, strict: false)
    }

    /// Whether these words start a sentence of their own, and with what kind of subject.
    static func startsSentence(_ toks: [Token], afterComma: Bool) -> SubjectKind? {
        guard toks.count >= 2 else { return nil }
        let first = toks[0]
        if joiners.contains(first.lower) || subordinators.contains(first.lower) { return nil }
        if first.lower == "please" {
            let v = toks[1]
            return v.tag == .verb && !v.lower.hasSuffix("ing") && !v.lower.hasSuffix("ed") ? .imperative : nil
        }
        guard let subj = subject(toks, at: 0, sentenceStart: false), subj.end < toks.count else { return nil }
        var j = subj.end
        if toks[j].tag == .adverb, j + 1 < toks.count { j += 1 }
        let v = toks[j]
        // ", I think", ", I'd say", ", we hope": an aside, not a second sentence.
        if subj.kind == .pronoun, toks.prefix(4).contains(where: { reporting.contains($0.lower) }) { return nil }
        // ", I'm afraid." and ", it works." are tails a careful writer may keep.
        if afterComma, toks.count <= 2 || toks.count == 3 && beForms.contains(v.lower) && takeClause.contains(toks[2].lower) { return nil }
        return finiteVerb(v, after: subj, strict: true) ? subj.kind : nil
    }

    /// The subject phrase starting at `i`: a pronoun, a name, or a determiner with its noun ("the coffee machine").
    static func subject(_ toks: [Token], at i: Int, sentenceStart: Bool) -> Subject? {
        let t = toks[i]
        if pronouns.contains(t.lower) { return Subject(end: i + 1, kind: .pronoun, plural: ["we", "you", "they", "these", "those"].contains(t.lower)) }
        if determiners.contains(t.lower) {
            var j = i + 1, head: Token?
            // "the remaining cartons", "the opening hours": an "-ing" word before the noun describes it.
            while j < toks.count, j - i <= 4, [.adjective, .noun, .number, .adverb].contains(toks[j].tag) || ["'s", "\u{2019}s"].contains(toks[j].lower)
                    || toks[j].tag == .verb && toks[j].lower.hasSuffix("ing") {
                if toks[j].tag == .noun { head = toks[j] }
                j += 1
            }
            guard let head, toks[j - 1].tag == .noun else { return nil }
            return Subject(end: j, kind: .noun, plural: ["these", "those", "both", "several", "many", "most", "few", "all", "some"].contains(t.lower) || isPlural(head))
        }
        if t.tag == .noun, t.text.first?.isUppercase == true, !sentenceStart {
            var j = i + 1
            while j < toks.count, j - i < 2, toks[j].tag == .noun, toks[j].text.first?.isUppercase == true { j += 1 }
            if j < toks.count, ["'s", "\u{2019}s"].contains(toks[j].lower) {
                // "Ella's shop will": the name owns the subject.
                j += 1
                while j < toks.count, j - i <= 4, [.adjective, .noun].contains(toks[j].tag) { j += 1 }
                guard toks[j - 1].tag == .noun else { return nil }
                return Subject(end: j, kind: .noun, plural: isPlural(toks[j - 1]))
            }
            return Subject(end: j, kind: .name, plural: false)
        }
        if t.tag == .noun, sentenceStart {
            var j = i + 1
            while j < toks.count, j - i < 2, toks[j].tag == .noun { j += 1 }
            return Subject(end: j, kind: .noun, plural: isPlural(toks[j - 1]))
        }
        return nil
    }

    static func isPlural(_ t: Token) -> Bool { t.lower.hasSuffix("s") && t.lemma != t.lower }

    /// A verb that carries tense: "is", "will", "has", "expects", "ordered". Not "-ing", and after a noun not a
    /// bare "-ed" form, which could be a participle ("a man named Sam") when strict.
    static func finiteVerb(_ v: Token, after s: Subject, strict: Bool) -> Bool {
        if auxiliaries.contains(v.lower) { return true }
        guard v.tag == .verb, !v.lower.hasSuffix("ing"), !["be", "been", "being"].contains(v.lower) else { return false }
        switch s.kind {
        case .pronoun, .imperative: return true
        case .name, .noun:
            let third = v.lower.hasSuffix("s") && v.lemma != v.lower
            if third { return !s.plural }
            if v.lower == v.lemma { return s.plural }
            return !strict
        }
    }
}
