import Foundation
import NaturalLanguage

/// A single subject with a plural verb when a phrase sits between them: "The box of lids are under the desk",
/// "The supplier who handles our candles deliver on Tuesdays", "One of our suppliers make these". The engines
/// read the nearest noun as the subject; this reads the head of the phrase. Plain code, no model.
enum Agreement {
    typealias Token = Splices.Token

    static let singularDeterminers: Set<String> = ["a", "an", "the", "this", "that", "each", "every", "our", "my", "your",
        "his", "her", "their", "its", "one", "another", "no"]
    static let singularPronouns: Set<String> = ["one", "each", "neither", "either", "everyone", "everybody", "nobody",
        "somebody", "someone", "anyone", "anybody"]
    /// Heads that take a plural verb or go either way: "a number of buyers are", "the team are", "the staff were".
    static let collective: Set<String> = ["number", "lot", "lots", "couple", "majority", "minority", "half", "third",
        "quarter", "percent", "percentage", "part", "rest", "plenty", "handful", "bunch", "group", "team", "family",
        "staff", "variety", "range", "series", "pair", "dozen", "hundred", "thousand", "million", "proportion", "fraction",
        "share", "total", "sum", "amount", "remainder", "bulk", "kind", "sort", "type", "mix", "array", "host", "crew",
        "committee", "board", "government", "management", "company", "public", "audience", "jury", "cast", "band",
        "class", "club", "firm", "army", "police", "people", "data", "media", "personnel", "cattle", "sheep", "fish",
        "species", "means", "offspring", "clergy", "youth", "press", "faculty", "majority", "generation", "population",
        "community", "crowd", "flock", "herd", "panel", "pack", "set", "stock", "folk", "cohort", "squad", "duo", "trio",
        "military", "aircraft", "spacecraft", "deer", "moose", "salmon", "trout", "bison", "elk", "swine", "headquarters",
        "barracks", "crossroads", "scissors", "trousers", "craft", "cod", "squid", "shrimp", "tuna", "reindeer", "buffalo",
        "criteria", "phenomena", "alumni", "bacteria", "dice", "none", "deal", "piece", "bit"]
    static let phraseOpeners: Set<String> = ["of", "with", "on", "in", "for", "from", "at", "by", "under", "over",
        "near", "behind", "beside", "between", "among", "without", "about", "to", "inside", "outside", "across", "along"]
    static let pluralAux = ["are": "is", "were": "was", "have": "has", "do": "does"]
    /// Past forms the lemmatizer leaves as they are ("saw", "ran"), and verbs whose past is their plain form ("cost").
    static let pastForms: Set<String> = ["saw", "ran", "came", "went", "became", "began", "drank", "drove", "fell", "felt",
        "found", "gave", "got", "grew", "had", "held", "kept", "knew", "led", "left", "lost", "made", "met", "paid", "read",
        "said", "sat", "sent", "shook", "sold", "spent", "stood", "took", "told", "thought", "threw", "understood", "woke",
        "won", "wore", "wrote", "bought", "brought", "built", "caught", "dealt", "did", "fed", "lit", "meant", "broke",
        "chose", "flew", "forgot", "froze", "hid", "rode", "rose", "sang", "sank", "shone", "spoke", "stole", "struck",
        "swam", "swore", "tore", "bore", "dug", "hung", "slid", "spun", "stuck", "stung", "swung", "wound", "bound",
        "fought", "sought", "taught", "lay", "laid", "ate", "bit", "blew", "drew", "ground", "lent", "bent", "spat",
        "cost", "put", "set", "cut", "hit", "let", "shut", "spread", "split", "quit", "hurt", "bet", "cast", "burst",
        "shed", "fit", "rid", "wed", "bid", "broadcast", "forecast", "upset", "offset", "reset", "input", "output", "beat"]

    static func issues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return }
            let toks = Splices.tokens(s)
            let base = NSRange(sr, in: text).location
            var i = 0
            while i < toks.count {
                // A subject starts the sentence or follows a comma, a conjunction or a word like "because".
                // A subject starts the sentence, follows its only comma ("After lunch, the buyer"), or follows a word
                // like "because". Not after "and" or a second comma, where it may be the last item of a list that
                // takes a plural verb; not after "that", where "requires that every supplier sign" wants the plain verb.
                let firstComma = i > 0 && toks[i - 1].text == "," && !toks[0..<(i - 1)].contains { $0.text == "," || $0.lower == "and" }
                let opens = i == 0 || firstComma
                    || Splices.subordinators.contains(toks[i - 1].lower) && !["that", "lest"].contains(toks[i - 1].lower)
                if opens, let (verb, fix) = plural(after: i, in: toks) {
                    let v = toks[verb]
                    let r = v.lower == "do" && verb + 1 < toks.count && toks[verb + 1].lower == "n't"
                        ? NSRange(location: v.range.location, length: NSMaxRange(toks[verb + 1].range) - v.range.location) : v.range
                    let original = (s as NSString).substring(with: r)
                    let rep = original.lowercased() == "don't" || original.lowercased() == "don\u{2019}t" ? "doesn't" : fix
                    out.append(Issue(range: r.shifted(by: base), kind: .grammar,
                                     message: "The verb agrees with \u{201C}\(head(at: i, in: toks))\u{201D}, which is one thing: \u{201C}\(rep)\u{201D}.",
                                     replacements: [rep], original: original))
                    i = verb
                }
                i += 1
            }
        }
        return out
    }

    static func head(at i: Int, in toks: [Token]) -> String {
        guard let (end, _) = subject(at: i, in: toks) else { return "" }
        return toks[i..<end].map(\.text).joined(separator: " ")
    }

    /// A single subject at `i` with its phrase, then a plural verb: the verb's index and its singular form.
    static func plural(after i: Int, in toks: [Token]) -> (Int, String)? {
        guard let (end, head) = subject(at: i, in: toks) else { return nil }
        var j = end
        // "of the lids", "who handles our candles": one phrase or one short relative clause may follow the head.
        if j < toks.count, phraseOpeners.contains(toks[j].lower) {
            guard let k = phraseEnd(from: j + 1, in: toks) else { return nil }
            j = k
        } else if j < toks.count, ["who", "that", "which"].contains(toks[j].lower) {
            guard j + 1 < toks.count, toks[j + 1].tag == .verb, toks[j + 1].lower.hasSuffix("s") else { return nil }
            var k = j + 2, n = 0
            while k < toks.count, n < 4, [.determiner, .adjective, .noun, .number, .pronoun].contains(toks[k].tag) { k += 1; n += 1 }
            guard n > 0, toks[k - 1].tag == .noun || toks[k - 1].tag == .pronoun else { return nil }
            j = k
        } else if head == nil {
            return nil  // "One" or "each" needs its "of" phrase
        }
        if j < toks.count, toks[j].tag == .adverb, !["n't", "not"].contains(toks[j].lower) { j += 1 }
        guard j < toks.count else { return nil }
        let v = toks[j]
        if let fix = pluralAux[v.lower] {
            // "need not" and "do not" after a plural phrase are not the common slip; "do n't" is.
            return (j, fix)
        }
        guard v.tag == .verb, v.lemma == v.lower, !Splices.auxiliaries.contains(v.lower), !Splices.reporting.contains(v.lower),
              !pastForms.contains(v.lower), !v.lower.hasSuffix("ing"), !v.lower.hasSuffix("ed"), v.lower.count >= 3 else { return nil }
        // The word after must read as an object or a pause, so "the price list" is never read as "the price lists".
        if j + 1 < toks.count {
            let n = toks[j + 1]
            let ok = [.determiner, .pronoun, .preposition, .adverb, .adjective, .particle, .number, .sentenceTerminator].contains(n.tag)
                || n.text == "," || ["to", "that", "n't", "not"].contains(n.lower)
            guard ok, n.lower != "not" || v.lower != "need" else { return nil }
        }
        return (j, thirdPerson(v.lower))
    }

    /// Determiner + noun ("the box", "this batch of"), or "one"/"each": the end index and the head noun.
    static func subject(at i: Int, in toks: [Token]) -> (Int, Token?)? {
        let t = toks[i]
        if singularPronouns.contains(t.lower), i + 1 < toks.count, toks[i + 1].lower == "of" { return (i + 1, nil) }
        guard singularDeterminers.contains(t.lower) else { return nil }
        var j = i + 1, head: Token?
        while j < toks.count, j - i <= 4, [.adjective, .noun, .number].contains(toks[j].tag) || toks[j].tag == .verb && toks[j].lower.hasSuffix("ing") {
            if toks[j].tag == .noun { head = toks[j] }
            j += 1
        }
        guard let head, toks[j - 1].tag == .noun, isSingular(head) else { return nil }
        return (j, head)
    }

    /// A common noun in its single form: lemma and word agree, no "-s", not a name, not a group word.
    static func isSingular(_ t: Token) -> Bool {
        guard t.lemma == t.lower, !t.lower.hasSuffix("s"), t.text.first?.isLowercase == true, !collective.contains(t.lower) else { return false }
        return true
    }

    /// The end of a phrase like "of the replacement lids" or "with the two tables": tokens up to the last noun.
    static func phraseEnd(from i: Int, in toks: [Token]) -> Int? {
        var j = i, last: Int?
        while j < toks.count, j - i < 6, [.determiner, .adjective, .noun, .number, .adverb].contains(toks[j].tag)
                || ["'s", "\u{2019}s"].contains(toks[j].lower) || toks[j].tag == .verb && toks[j].lower.hasSuffix("ing") {
            if toks[j].tag == .noun { last = j }
            j += 1
        }
        guard let last, last == j - 1 else { return nil }
        return j
    }

    static func thirdPerson(_ v: String) -> String {
        if v == "have" { return "has" }
        if v == "go" || v == "do" { return v + "es" }
        if v.hasSuffix("s") || v.hasSuffix("x") || v.hasSuffix("z") || v.hasSuffix("ch") || v.hasSuffix("sh") || v.hasSuffix("o") { return v + "es" }
        if v.hasSuffix("y"), let p = v.dropLast().last, !"aeiou".contains(p) { return String(v.dropLast()) + "ies" }
        return v + "s"
    }
}
