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
        "near", "behind", "beside", "between", "among", "without", "about", "to", "inside", "outside", "across", "along",
        "beneath", "below", "above", "underneath", "around", "throughout", "within"]
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
                } else if opens || i > 1 && toks[i - 2].text == "," && ["but", "yet", "so"].contains(toks[i - 1].lower),
                          let (verb, fix, head) = singular(after: i, in: toks) {
                    let v = toks[verb]
                    let r = v.lower == "does" && verb + 1 < toks.count && toks[verb + 1].lower == "n't"
                        ? NSRange(location: v.range.location, length: NSMaxRange(toks[verb + 1].range) - v.range.location) : v.range
                    let original = (s as NSString).substring(with: r)
                    let rep = r.length > v.range.length ? "don't" : fix
                    out.append(Issue(range: r.shifted(by: base), kind: .grammar,
                                     message: "The verb agrees with \u{201C}\(head)\u{201D}, which is more than one: \u{201C}\(rep)\u{201D}.",
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
        } else if j < toks.count, toks[j].tag == .verb, toks[j].lower.hasSuffix("ed"), j + 1 < toks.count,
                  phraseOpeners.contains(toks[j + 1].lower), head != nil {
            // "The deposit listed in these proposals cover our": a describing "-ed" phrase. The "-ed" word may be the
            // sentence's own past verb ("The buyer looked at the display stand"), so the verb after must take an object.
            guard let k = phraseEnd(from: j + 2, in: toks), k + 1 < toks.count, toks[k].tag == .verb,
                  Apostrophes.canBeVerb(toks[k].lower), !nounEnding(toks[k].lower),
                  [.determiner, .pronoun].contains(toks[k + 1].tag) else { return nil }
            j = k
        } else if j < toks.count, ["who", "that", "which"].contains(toks[j].lower) {
            // "who handles our candles", "who ordered these mugs": the clause's own verb, present or past.
            guard j + 1 < toks.count, toks[j + 1].tag == .verb,
                  toks[j + 1].lower.hasSuffix("s") || toks[j + 1].lower.hasSuffix("ed") || pastForms.contains(toks[j + 1].lower),
                  !Splices.auxiliaries.contains(toks[j + 1].lower), !Splices.reporting.contains(toks[j + 1].lower),
                  !Rules.clauseVerbs.contains(toks[j + 1].lower) else { return nil }
            var k = j + 2, n = 0
            while k < toks.count, n < 4, [.determiner, .adjective, .noun, .number, .pronoun].contains(toks[k].tag),
                  !["which", "what", "whose", "that", "who", "how", "where", "when", "why"].contains(toks[k].lower) { k += 1; n += 1 }
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
        // Plain form only: not "-ing", not a past form ("ordered", but "need" and "succeed" are plain forms).
        guard v.tag == .verb, v.lemma == v.lower, !Splices.auxiliaries.contains(v.lower), !pastForms.contains(v.lower),
              !v.lower.hasSuffix("ing"), !v.lower.hasSuffix("ed") || v.lower.hasSuffix("eed"), v.lower.count >= 3 else { return nil }
        // The word after must read as an object or a pause, so "the price list" is never read as "the price lists".
        if j + 1 < toks.count {
            let n = toks[j + 1]
            // After a phrase or clause the subject is plain, so a noun object is safe: "near the windows attract
            // attention". Right after the subject it may be one name: "the price list items".
            let ok = [.determiner, .pronoun, .preposition, .adverb, .adjective, .particle, .number, .sentenceTerminator].contains(n.tag)
                || n.text == "," || ["to", "that", "n't", "not"].contains(n.lower)
                || n.tag == .verb && n.lower.hasSuffix("ing") || n.tag == .noun && j > end
            guard ok, n.lower != "not" || v.lower != "need" else { return nil }
        }
        return (j, thirdPerson(v.lower))
    }

    // The other way round: "Those replacement shelves fits", "The labels on the sample jars is".
    static let pluralDeterminers: Set<String> = ["the", "these", "those", "our", "your", "my", "his", "her", "their",
        "all", "both", "some", "many", "several", "few", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    static let singularAux = ["is": "are", "was": "were", "has": "have", "does": "do"]
    /// Plurals that name one amount ("ten dollars is plenty") and words that end in s but are one thing.
    static let amounts: Set<String> = ["dollars", "pounds", "euros", "cents", "pence", "years", "months", "weeks", "days",
        "hours", "minutes", "seconds", "miles", "kilometres", "kilometers", "metres", "meters", "feet", "inches", "percent",
        "points", "litres", "liters", "gallons", "kilos", "grams", "tons", "tonnes", "news", "series", "species", "means",
        "physics", "mathematics", "economics", "politics", "ethics", "athletics", "headquarters", "whereabouts", "thanks",
        "odds", "basics", "sales", "earnings", "proceeds", "goods", "logistics", "analytics", "statistics", "mechanics"]
    static let relativeWords: Set<String> = ["who", "that", "which"]

    /// A plural subject at `i` with at most one phrase or short clause after it, then a singular verb: the verb's
    /// index, its plural form, and the subject's words.
    static func singular(after i: Int, in toks: [Token]) -> (Int, String, String)? {
        guard pluralDeterminers.contains(toks[i].lower) else { return nil }
        var j = i + 1, head: Token?
        while j < toks.count, j - i <= 4, [.adjective, .noun, .number].contains(toks[j].tag)
                || toks[j].tag == .verb && (toks[j].lower.hasSuffix("ed") || toks[j].lower.hasSuffix("ing")) {
            // "the reason good products exist": a describing word after a noun starts a second phrase.
            if head != nil, toks[j].tag != .noun { return nil }
            if toks[j].tag == .noun { head = toks[j] }
            j += 1
        }
        guard let head, toks[j - 1].tag == .noun, head.text.first?.isLowercase == true, head.lower.hasSuffix("s"),
              head.lemma != head.lower, !amounts.contains(head.lower), !collective.contains(head.lemma) else { return nil }
        let subject = toks[i..<j].map(\.text).joined(separator: " ")
        // "The government benefits from": after another noun, an "-s" word followed by a phrase may be the verb.
        if j - 1 > i + 1, toks[j - 2].tag == .noun, j < toks.count, phraseOpeners.contains(toks[j].lower) { return nil }
        // "on the sample jars", "supplied with our quote", "who fitted your lights": one phrase or one short clause.
        if j < toks.count, toks[j].tag == .verb, toks[j].lower.hasSuffix("ed"), j + 1 < toks.count, phraseOpeners.contains(toks[j + 1].lower) {
            guard let k = phraseEnd(from: j + 2, in: toks) else { return nil }
            j = k
        } else if j < toks.count, phraseOpeners.contains(toks[j].lower) {
            guard let k = phraseEnd(from: j + 1, in: toks) else { return nil }
            j = k
        }
        guard j < toks.count, !relativeWords.contains(toks[j].lower) else { return nil }
        let v = toks[j]
        if let fix = singularAux[v.lower] { return (j, fix, subject) }
        // A present "-s" form: "fits", "requires", "matches". Not "was" or a past form, and not a noun the tagger
        // took for a verb.
        guard v.tag == .verb, v.text.first?.isLowercase == true, v.lower.count >= 4, v.lemma != v.lower,
              v.lower == v.lemma + "s" || v.lower == v.lemma + "es" || v.lemma.hasSuffix("y") && v.lower == v.lemma.dropLast() + "ies"
        else { return nil }
        // "as the liberal arts undergraduates and started": the tagger can call a plural noun a verb, and a noun
        // ends its phrase where a verb would go on.
        guard Apostrophes.canBeVerb(v.lemma), j + 1 < toks.count, !["and", "or", "nor"].contains(toks[j + 1].lower),
              toks[j + 1].tag != .punctuation, toks[j + 1].tag != .sentenceTerminator else { return nil }
        return (j, v.lemma, subject)
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
                || ["'s", "\u{2019}s"].contains(toks[j].lower) || toks[j].tag == .verb && toks[j].lower.hasSuffix("ing")
                || toks[j].tag == .verb && toks[j].lower.hasSuffix("ed") && j > i && toks[j - 1].tag == .determiner {
            if toks[j].tag == .noun { last = j }
            j += 1
        }
        guard let last, last == j - 1 else { return nil }
        return j
    }

    /// Endings only nouns have ("delivery", "payment"), for words the tagger calls verbs by their place.
    static func nounEnding(_ w: String) -> Bool {
        ["tion", "sion", "ment", "ness", "ity", "ery", "ance", "ence", "ship", "hood", "ism"].contains { w.hasSuffix($0) }
    }

    static func thirdPerson(_ v: String) -> String {
        if v == "have" { return "has" }
        if v == "go" || v == "do" { return v + "es" }
        if v.hasSuffix("s") || v.hasSuffix("x") || v.hasSuffix("z") || v.hasSuffix("ch") || v.hasSuffix("sh") || v.hasSuffix("o") { return v + "es" }
        if v.hasSuffix("y"), let p = v.dropLast().last, !"aeiou".contains(p) { return String(v.dropLast()) + "ies" }
        return v + "s"
    }
}
