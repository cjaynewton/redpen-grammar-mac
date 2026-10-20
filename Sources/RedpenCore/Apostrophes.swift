import Foundation
import NaturalLanguage

/// Apostrophes the engines miss: a name that owns something with no apostrophe ("Mayas notes"; the dictionary
/// takes "Mayas" as a plural, so spelling never flags it), one person owning something ("the bakers invoice"),
/// and an apostrophe in a plain plural ("three vacancy's", "the battery's are"). Plain code, no model.
enum Apostrophes {
    typealias Token = Splices.Token

    /// Names that end in s as written, so "James notes" is never read as "Jame's notes". Common given names,
    /// surnames, places and shop names.
    static let sNames: Set<String> = ["james", "thomas", "lucas", "marcus", "nicholas", "douglas", "charles", "chris",
        "carlos", "luis", "andreas", "elias", "tobias", "silas", "jesus", "lewis", "louis", "francis", "frances", "dennis",
        "curtis", "otis", "morris", "harris", "davis", "ellis", "willis", "phyllis", "iris", "doris", "agnes", "lois",
        "gladys", "jules", "miles", "giles", "rhys", "gus", "russ", "wes", "les", "hans", "klaus", "linus", "angus",
        "julius", "cyrus", "atlas", "amos", "moses", "jonas", "magnus", "matthias", "demetrius", "marius", "cassius",
        "jones", "williams", "adams", "roberts", "peters", "edwards", "evans", "collins", "phillips", "rogers", "hughes",
        "stevens", "stephens", "parsons", "simmons", "owens", "jenkins", "perkins", "hopkins", "watkins", "wilkins",
        "richards", "reynolds", "rhodes", "banks", "burns", "myers", "hayes", "gibbs", "holmes", "wells", "sims",
        "woods", "mills", "fields", "rivers", "brooks", "daniels", "matthews", "andrews", "michaels", "nichols", "lyons",
        "barnes", "graves", "haynes", "mathis", "reyes", "torres", "flores", "santos", "ramos", "cortes", "gomes",
        "travis", "chambers", "sanders", "powers", "waters", "summers", "masters", "peoples", "childs", "giles",
        "texas", "kansas", "arkansas", "paris", "athens", "wales", "brussels", "naples", "dallas", "memphis", "vegas",
        "angeles", "netherlands", "philippines", "bahamas", "barbados", "honduras", "venus", "mars", "zeus", "hermes",
        "starbucks", "walgreens", "loblaws", "sobeys", "sears", "lowes", "macys", "kohls", "dillards", "harrods",
        "sainsburys", "selfridges", "boots", "sons", "brothers", "bros", "christians", "muslims", "texans", "victorians",
        "catholics", "protestants", "democrats", "republicans", "mormons", "quakers", "hindus", "buddhists", "sikhs", "tesco", "wendys", "dennys", "applebees", "chilis", "adidas", "lexus", "levis"]

    /// People and businesses, the nouns that own things in "the suppliers address" or "each applicants references".
    static let owners: Set<String> = ["customer", "client", "supplier", "manager", "driver", "baker", "applicant",
        "owner", "buyer", "seller", "worker", "employee", "employer", "tenant", "landlord", "landlady", "partner",
        "founder", "retailer", "vendor", "distributor", "director", "teacher", "student", "parent", "patient", "user",
        "player", "officer", "editor", "author", "writer", "reader", "caller", "visitor", "guest", "friend", "neighbour",
        "neighbor", "colleague", "contractor", "builder", "plumber", "electrician", "engineer", "designer", "developer",
        "investor", "shareholder", "consumer", "shopper", "cashier", "assistant", "accountant", "lawyer", "doctor",
        "nurse", "chef", "farmer", "homeowner", "resident", "candidate", "volunteer", "trainee", "intern", "apprentice",
        "technician", "installer", "inspector", "courier", "broker", "dealer", "merchant", "wholesaler", "manufacturer",
        "producer", "supervisor", "receptionist", "architect", "estimator", "surveyor", "photographer", "florist",
        "butcher", "printer", "agent", "lender", "borrower", "member", "subscriber", "recruiter", "interviewer",
        "coordinator", "administrator", "operator", "landscaper", "decorator", "painter", "carpenter", "cleaner",
        "gardener", "brand", "company", "business", "shop", "store", "firm", "school", "council", "charity", "bank",
        "factory", "warehouse", "bakery", "restaurant", "hotel", "agency", "studio", "salon", "clinic"]

    static let determiners: Set<String> = ["the", "our", "your", "my", "his", "her", "their", "its", "each", "every",
        "a", "an", "this", "that", "one", "another"]
    /// Words that only come before a plural: "three vacancy's" means more than one vacancy.
    static let pluralCues: Set<String> = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "dozen", "several", "many", "few", "multiple",
        "numerous", "various", "these", "those"]
    static let pluralVerbs: Set<String> = ["are", "were", "have", "do", "aren't", "weren't", "haven't", "don't",
        "aren\u{2019}t", "weren\u{2019}t", "haven\u{2019}t", "don\u{2019}t"]
    /// Words that take 's for "is" or own nothing countable: "it's", "let's", "everyone's", "people's".
    static let notPlural: Set<String> = ["it", "that", "what", "there", "here", "who", "let", "one", "everyone", "someone",
        "anyone", "nobody", "everybody", "somebody", "anybody", "he", "she", "where", "how", "why", "when", "today",
        "tonight", "yesterday", "tomorrow", "nothing", "everything", "something", "anything", "this", "other", "another",
        "people", "children", "men", "women", "staff", "world", "year", "week", "month", "day", "hour", "minute", "night"]

    static func issues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, _ in
            guard let s else { return }
            let toks = Splices.tokens(s)
            let base = NSRange(sr, in: text).location
            func add(_ r: NSRange, _ msg: String, _ reps: [String]) {
                let at = r.shifted(by: base)
                guard !out.contains(where: { $0.range.overlaps(at) }) else { return }
                out.append(Issue(range: at, kind: .grammar, message: msg, replacements: reps, original: (s as NSString).substring(with: r)))
            }
            for i in toks.indices {
                if let fix = namePossessive(toks, i) {
                    add(toks[i].range, "Something belongs to \(fix.dropLast(2)) here: \u{201C}\(fix)\u{201D}.", [fix])
                } else if let (single, many) = ownerPossessive(toks, i) {
                    add(toks[i].range, "Something belongs to the \(single.dropLast(2)) here: \u{201C}\(single)\u{201D}.", [single, many])
                }
            }
            for (r, fix) in pluralApostrophes(s, toks) {
                add(r, "More than one, so no apostrophe: \u{201C}\(fix)\u{201D}.", [fix])
            }
        }
        return out
    }

    /// "Mayas notes" -> "Maya's notes": a capitalised word that is a first name plus s, then the thing owned.
    static func namePossessive(_ toks: [Token], _ i: Int) -> String? {
        let t = toks[i]
        guard t.text.count >= 4, t.text.hasSuffix("s"), !t.text.hasSuffix("ss"), t.text.first?.isUppercase == true,
              t.text.dropFirst().allSatisfy({ $0.isLowercase }), !sNames.contains(t.lower) else { return nil }
        // "the Harpers", "Serena Williams": a family or a surname, not an owner. "asked Jacobs questions": two objects.
        if i > 0, determiners.contains(toks[i - 1].lower) && toks[i - 1].lower != "that" || toks[i - 1].text.first?.isUppercase == true && i > 1
            || twoObjects.contains(toks[i - 1].lower) { return nil }
        // At the start of a sentence a capital is no sign of a name ("This", "Previous"), so the word must read as a noun.
        if i == 0, t.tag != .noun { return nil }
        // The tagger misreads words after a name it does not know ("Leos offer letter"), so up to two describing
        // words or verb forms may sit before the noun owned.
        var j = i + 1
        while j < toks.count, j - i <= 3, toks[j].tag != .noun || timeNouns.contains(toks[j].lower) {
            guard [.adjective, .verb].contains(toks[j].tag), toks[j].text.first?.isLowercase == true,
                  !Splices.auxiliaries.contains(toks[j].lower) else { return nil }
            // At the start of a clause a plain verb here is the plural's own verb: "Americans love home-spun wisdom".
            if toks[j].tag == .verb, !toks[j].lower.hasSuffix("ed"), i == 0 || toks[i - 1].text == "," { return nil }
            j += 1
        }
        guard j < toks.count, j - i <= 3, toks[j].text.first?.isLowercase == true else { return nil }
        if j + 1 < toks.count, Splices.determiners.contains(toks[j + 1].lower) || ["it", "them", "us", "me", "him"].contains(toks[j + 1].lower) { return nil }
        // At the start of a clause the name may be a plural doing something ("Birkins trade at", "Jacobs works hard"):
        // it owns the noun only when the sentence's own verb comes later ("Nadias ladder is").
        if i == 0 || toks[i - 1].text == "," || toks[i - 1].lower == "that" {
            guard toks[(j + 1)...].contains(where: { Splices.auxiliaries.contains($0.lower) || $0.tag == .verb }) else { return nil }
        }
        let name = String(t.text.dropLast())
        guard isNamePlural(t.lower, name) else { return nil }
        return name + "'s"
    }

    /// Whether the word reads as a first name plus s. The tagger's own lemma says so for names it knows
    /// ("mayas" -> "Maya", but "jacobs" -> "Jacobs" and "sons" -> "son"). For a name it does not know, the name
    /// must end like most first names (Priya, Ravi, Theo) and read as a person's name on its own.
    static func isNamePlural(_ lower: String, _ name: String) -> Bool {
        let s = "The \(lower) are here."
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = s
        guard let r = s.range(of: lower) else { return false }
        if let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue, lemma != name { return false }
        // "Americans" also has a capitalised lemma; a person's name must read as one.
        return isFirstName(name) && (tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0 != nil || "aio".contains(name.last ?? "x"))
    }

    /// Verbs that take two objects: "asked Jacobs questions" names a person, then a thing.
    static let twoObjects: Set<String> = ["ask", "asked", "asks", "give", "gave", "gives", "given", "tell", "told", "tells",
        "send", "sent", "sends", "show", "showed", "shows", "offer", "offered", "offers", "pay", "paid", "pays", "owe",
        "owed", "bring", "brought", "buy", "bought", "lend", "lent", "teach", "taught", "call", "called", "make", "made",
        "wish", "wished", "promise", "promised", "email", "emailed", "text", "texted", "charge", "charged", "cost"]
    static let timeNouns: Set<String> = Splices.timeWords.union(["morning", "afternoon", "evening", "night", "week",
        "month", "year", "weekend", "today", "tonight", "now", "then"])

    /// The thing owned right after a possessive: a lowercase noun, or one or two describing words and then one.
    /// The word after it must not be an object ("the bakers invoice the shops monthly" is a verb).
    static func ownedNoun(_ toks: [Token], after i: Int) -> Int? {
        var j = i + 1, adjectives = 0
        while j < toks.count, toks[j].tag == .adjective, adjectives < 2 { j += 1; adjectives += 1 }
        guard j < toks.count, toks[j].tag == .noun, toks[j].text.first?.isLowercase == true else { return nil }
        if j + 1 < toks.count, Splices.determiners.contains(toks[j + 1].lower) && !["all", "both"].contains(toks[j + 1].lower)
            || ["it", "them", "us", "me", "him"].contains(toks[j + 1].lower) { return nil }
        return j
    }

    /// Whether the word can be a plain-form verb ("trade", "work"), read in "They trade it."
    static func canBeVerb(_ w: String) -> Bool {
        let s = "They \(w) it."
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        guard let r = s.range(of: w) else { return false }
        return tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0 == .verb
    }

    /// Whether the tagger reads the word as a person's name on its own ("Maya is here", "I met Harper").
    static func isFirstName(_ name: String) -> Bool {
        for s in ["\(name) is here.", "I met \(name) today."] {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = s
            guard let r = s.range(of: name) else { continue }
            if tagger.tag(at: r.lowerBound, unit: .word, scheme: .nameType).0 == .personalName { return true }
        }
        return false
    }

    /// "Our suppliers address appears" -> "supplier's": a determiner, a person or business with an s, then the
    /// thing owned. Both fixes are offered, one owner first.
    static func ownerPossessive(_ toks: [Token], _ i: Int) -> (String, String)? {
        let t = toks[i]
        guard i > 0, determiners.contains(toks[i - 1].lower), t.text.first?.isLowercase == true, t.lower.hasSuffix("s"),
              let one = singular(t.lower), owners.contains(one), let owned = ownedNoun(toks, after: i) else { return nil }
        // "our users care about": a plain verb right after is the plural's own verb unless the sentence's verb comes
        // later ("our suppliers address appears").
        if owned == i + 1, !toks[owned].lower.hasSuffix("s"), canBeVerb(toks[owned].lower) {
            guard toks[(owned + 1)...].contains(where: { Splices.auxiliaries.contains($0.lower) || $0.tag == .verb }) else { return nil }
        }
        return (one + "'s", t.text + "'")
    }

    static func singular(_ w: String) -> String? {
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") || w.hasSuffix("shes") || w.hasSuffix("ches") || w.hasSuffix("xes") { return String(w.dropLast(2)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return nil
    }

    static func plural(_ w: String) -> String {
        if w.hasSuffix("y"), let p = w.dropLast().last, !"aeiou".contains(p) { return String(w.dropLast()) + "ies" }
        if w.hasSuffix("s") || w.hasSuffix("x") || w.hasSuffix("z") || w.hasSuffix("ch") || w.hasSuffix("sh") { return w + "es" }
        return w + "s"
    }

    static let apostropheS = try! NSRegularExpression(pattern: "\\b([a-z]+)['\u{2019}]s\\b")

    /// "three vacancy's", "the battery's are": a word that counts more than one, or a plural verb after.
    static func pluralApostrophes(_ s: String, _ toks: [Token]) -> [(NSRange, String)] {
        let ns = s as NSString
        var out: [(NSRange, String)] = []
        for m in apostropheS.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard word.count >= 3, !notPlural.contains(word) else { continue }
            let before = toks.last { NSMaxRange($0.range) <= m.range.location }
            let after = toks.first { $0.range.location >= NSMaxRange(m.range) }
            guard let w = toks.first(where: { $0.range.location == m.range.location }), w.tag == .noun else { continue }
            if let b = before, pluralCues.contains(b.lower) || b.text.allSatisfy(\.isNumber) && b.text != "1" {
                // "two year's notice" wants "years'"; "three vacancy's to fill" wants "vacancies".
                let owns = after.map { $0.tag == .noun } ?? false
                out.append((m.range, owns ? plural(word) + "'" : plural(word)))
            } else if let a = after, pluralVerbs.contains(a.lower) || a.lower == "do" {
                out.append((m.range, plural(word)))
            }
        }
        return out
    }
}
