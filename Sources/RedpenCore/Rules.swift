import Foundation
import NaturalLanguage

/// Grammar patterns the other engines miss, plus the optional house-style rules. Plain code, no model.
public enum Rules {
    static let dashes = try! NSRegularExpression(pattern: "\\s*(\u{2014}|\\s\u{2013}\\s|\\s--\\s)\\s*")
    // A colon joining two clauses. Labels ("Capital deployed: $400K"), times, URLs and lists are skipped below.
    static let colon = try! NSRegularExpression(pattern: "([A-Za-z\\)\"'])(:)\\s+([A-Za-z][^\\n]*)")
    public static func check(_ text: String, longform: Bool, style: HouseStyle = HouseStyle()) -> [Issue] {
        var out: [Issue] = patternIssues(text)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for m in style.noDashes ? dashes.matches(in: text, range: full) : [] {
            out.append(Issue(range: m.range, kind: .voice, message: "No em dashes. Use a period or a comma.",
                             replacements: [", ", ". "], original: ns.substring(with: m.range)))
        }

        for m in style.colonsOnlyForLabels ? colon.matches(in: text, range: full) : [] {
            let colonR = m.range(at: 2)
            let rest = ns.substring(with: m.range(at: 3))
            // Only the rest of this sentence counts: "qualification: five years. J-League ..." is a label.
            let after = rest.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? rest
            let lineStart = ns.lineRange(for: NSRange(location: colonR.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: colonR.location - lineStart))
            // Words since the sentence began: "The net result: ..." is a three-word label mid-paragraph.
            let before = line.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? line
            let beforeWords = before.split(whereSeparator: { $0 == " " }).count
            let afterWords = after.split(separator: " ").count
            // Labels are short and start the line; a literal list after a colon is fine.
            if beforeWords <= 4 { continue }
            if afterWords < 4 || after.contains(",") && after.split(separator: ",").count >= 3 { continue }
            // "two variables: income growth and fatalities" announces a list.
            if before.range(of: "\\b(two|three|four|five|six|several|\\d+) [a-z-]+s$", options: .regularExpression) != nil { continue }
            if before.hasSuffix("http") || before.hasSuffix("https") { continue }
            let first = String(after.prefix(1)).uppercased()
            let span = NSRange(location: colonR.location, length: m.range(at: 3).location + 1 - colonR.location)
            out.append(Issue(range: span, kind: .voice,
                             message: "Colon used as a connector. Make it a period.",
                             replacements: [". " + first], original: ns.substring(with: span)))
        }

        // Search the original text, ignoring case, so ranges stay right when lowercasing changes a string's length.
        for phrase in style.disclaimers where !phrase.isEmpty {
            var r = ns.range(of: phrase, options: .caseInsensitive)
            while r.location != NSNotFound {
                out.append(Issue(range: r, kind: .voice, message: "Disclaimer. Cut it and let the evidence speak.",
                                 replacements: [""], original: ns.substring(with: r)))
                let next = r.location + r.length
                r = ns.range(of: phrase, options: .caseInsensitive, range: NSRange(location: next, length: ns.length - next))
            }
        }

        if longform, !style.containerWords.isEmpty {
            let words = Set(style.containerWords.map { $0.lowercased() })
            text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, wr, _, _ in
                guard let word, words.contains(word.lowercased()) else { return }
                out.append(Issue(range: NSRange(wr, in: text), kind: .voice,
                                 message: "\"\(word)\" is a container word. Say the concrete thing.",
                                 replacements: [], original: word))
            }
        }

        out += StarterSet.issues(text, sets: style.starterSets,
                                 skip: longform ? ownWords(style) : [])

        if style.flagOtherLanguages { out += languageIssues(text) }
        return out
    }

    /// The own-list words the container-word check will flag. It matches single words only, so a phrase on the list
    /// leaves the starter sets to catch it.
    static func ownWords(_ style: HouseStyle) -> Set<String> {
        Set(style.containerWords.map { $0.lowercased() }.filter { !$0.contains(" ") })
    }

    // Grammar slips the small model lets through.
    static let meAnd = try! NSRegularExpression(pattern: "(?:^|(?<=[.!?]\\s))(Me and ([A-Z][a-z]+|(?:the|my|our|your|his|her|their) [a-z]+))\\b(?=\\s+[a-z]+(?:ed|s)?\\b)")
    static let andMe = try! NSRegularExpression(pattern: "(?:^|(?<=[.!?]\\s))([A-Z][a-z]+ and (me|him|her|us|them))\\b(?=\\s+[a-z]+(?:ed|s)?\\b)")
    static let eachHave = try! NSRegularExpression(pattern: "\\b(?:Each|Every one|Neither|Either) of (?:the |our |their |these |those )?\\w+ (have|are|were|do|don't)\\b", options: [.caseInsensitive])

    // "to you and she", "invited Maya and I": after a preposition or a verb, the pronoun takes its object form.
    static let objectForm = ["I": "me", "he": "him", "she": "her", "we": "us", "they": "them"]
    static let andI = try! NSRegularExpression(pattern:
        "\\b([a-z]+) ((?:[A-Z][a-z]+|me|you|him|her|us|them|(?:the|my|our|your|his|her|their|this|that) [a-z]+(?: [a-z]+)?) and )(I|he|she|we|they)\\b(?=\\s*(?:[.,!?;:]|$|(?:to|that|about|for|in|at|on|the|a|an|some|our|your|his|her|their|my|its|this|these|those|how|what|when|where|why|whether|if|everything|something|nothing|anything|more|enough|one|two|three|\\d)\\b))")
    static let prepositions: Set<String> = ["to", "for", "with", "from", "between", "at", "by", "of", "about", "without",
        "against", "among", "toward", "towards", "behind", "beside", "near", "unlike", "upon", "onto", "into", "via",
        "despite", "regarding", "concerning", "after", "before", "beyond", "except", "including"]
    // "Him approved the budget", "Her will brief the team": a subject in its object form at the start of a sentence.
    static let objectSubject = try! NSRegularExpression(pattern:
        "(?:^|(?<=[.!?]\\s))(?:(Me|Him|Us|Them)(?= (?:will|would|can|could|should|must|might|may|shall|did|does|has|have|had|was|were|is|are|am|[a-z]+ed)\\b)|(Her)(?= (?:will|would|can|could|should|must|might|may|shall) (?!be\\b)[a-z]+\\b))")
    static let subjectForm = ["Me": "I", "Him": "He", "Her": "She", "Us": "We", "Them": "They"]
    // "send it to I", "a briefing for they before": a subject pronoun alone after a preposition or a verb, then a pause
    // or the next phrase. Only "I" is ever capitalised, so a name or a heading never matches.
    static let loneSubject = try! NSRegularExpression(pattern:
        "\\b([a-z]+) (I|he|she|we|they)\\b(?=\\s*(?:[.,!?;:]|$|(?:the|a|an|our|your|his|her|their|my|this|that|these|those|about|before|after|at|on|in|with|for|to|from|until|tomorrow|today|tonight)\\b))")

    // "We have too interviews booked": "too" never comes right before a plural noun, so the number was meant.
    // "two much", "two late.": "two" never comes before "much" or a describing word that ends the phrase.
    static let tooTwo = try! NSRegularExpression(pattern: "\\b([Tt]oo) ([a-z]+s)\\b")
    static let twoToo = try! NSRegularExpression(pattern:
        "\\b([Tt]wo) (?:much|many|(?:late|early|soon|far|long|busy|expensive|cheap|small|big|high|low|hot|cold|slow|fast|often|little)(?=\\s*(?:[.,!?;:]|$|(?:to|for|and|or|but|so)\\b)))\\b")

    // "Our distributor agreed collect the cases", "remind the new cashier submit her details": verbs that need "to"
    // before the next verb. Only a plain verb followed by its own object counts, so "plans review sessions" is safe.
    static let wantsTo = "(?:agree|agreed|agrees|plan|planned|plans|hope|hoped|hopes|decide|decided|decides|try|tried|tries|attempt|attempted|manage|managed|fail|failed|refuse|refused|promise|promised|intend|intended|intends|aim|aimed|prepare|prepared|arrange|arranged|would like|'d like|\u{2019}d like|want|wants|wanted|need|needs|needed|forget|forgot|remember|remembered|choose|chose|seem|seemed|seems|deserve|deserved|afford|hesitate|expect|expected|expects|wish|wished|offer|offered|threaten|threatened|neglect|neglected)"
    static let wantsObjectTo = "(?:would like|'d like|\u{2019}d like|want|wants|wanted|need|needs|needed|ask|asks|asked|remind|reminds|reminded|tell|tells|told|expect|expects|expected|allow|allows|allowed|encourage|encourages|encouraged|invite|invites|invited|require|requires|required|urge|urged|advise|advised|instruct|instructed|persuade|persuaded|force|forced|get|got|teach|taught)"
    static let missingTo = try! NSRegularExpression(pattern:
        "\\b(?:\(wantsTo)|\(wantsObjectTo) (?:me|you|him|her|us|them|[A-Z][a-z]+|(?:the|our|your|my|his|her|their|this|that|each|every) (?:(?!(?:to|and|or|but|that|not|never)\\b)[a-z]+ ){0,2}(?!(?:to|and|or|but|that)\\b)[a-z]+)) ([a-z]+)(?= (?:the|a|an|our|your|my|his|her|their|its|this|that|these|those|it|them|us|me|him)\\b)")
    static let notBare: Set<String> = Splices.auxiliaries.union(["be", "been", "not", "never", "always", "also", "just",
        "really", "only", "even", "still", "already", "all", "both", "back", "out", "up", "off", "in", "on", "over",
        "about", "for", "with", "from", "into", "help", "please", "and", "or", "but", "so", "that", "than", "if"])

    /// Verbs that take a whole clause, where "I" is right: "I hope Maya and I can go".
    static let clauseVerbs: Set<String> = Splices.reporting.union(["wish", "wished", "knew", "hoped", "guessed", "meant",
        "assumed", "supposed", "felt", "realised", "realized", "noticed", "remember", "remembered", "forget", "forgot",
        "decide", "decided", "require", "required", "request", "requested", "demand", "demanded", "recommend",
        "recommended", "ensure", "ensured", "doubt", "doubted", "mind", "pretend", "sure", "glad", "is", "was", "are",
        "were", "be", "been", "am", "like"])

    /// Fixed pairs where one preposition is right: "interested in", "proud of", "reply to".
    static let collocations: [(String, [String], String)] = [
        ("interested", ["on", "at", "for"], "in"), ("proud", ["for", "about", "on"], "of"), ("allergic", ["of", "for", "from"], "to"),
        ("reply", ["at"], "to"), ("replied", ["at"], "to"), ("look forward", ["for", "on"], "to"), ("looking forward", ["for", "on"], "to"),
        ("insist", ["for", "in", "to"], "on"), ("insisted", ["for", "in", "to"], "on"), ("depend", ["of", "in", "from"], "on"),
        ("depends", ["of", "in", "from"], "on"), ("consist", ["in", "from"], "of"), ("consists", ["in", "from"], "of"),
        ("capable", ["to", "for"], "of"), ("responsible", ["of", "on"], "for"), ("afraid", ["from", "for"], "of"),
        ("comply", ["to"], "with"), ("complies", ["to"], "with"), ("complied", ["to"], "with"), ("complying", ["to"], "with"),
        ("similar", ["with"], "to"), ("aware", ["about"], "of"), ("superior", ["than"], "to"), ("inferior", ["than"], "to"),
        ("married", ["with"], "to"), ("listen", ["at"], "to"), ("listened", ["at"], "to"), ("entitled", ["a", "an", "the", "one"], "to"),
    ]
    static let collocationRegex: NSRegularExpression = {
        let alts = collocations.map { "(?:\\b\($0.0) (?:\($0.1.joined(separator: "|")))\\b)" }.joined(separator: "|")
        return try! NSRegularExpression(pattern: alts, options: [.caseInsensitive])
    }()

    // "you're revised invoice", "they're latest catalog": these words only ever follow something owned.
    static let owned = "(?:latest|newest|own|first|next|last|final|revised|updated|current|favourite|favorite|main|usual|previous|original|entire|whole|upcoming|existing|new|old|recent|monthly|weekly|annual|yearly|daily)"
    static let contractedOwner = try! NSRegularExpression(pattern: "\\b(you['\u{2019}]re|they['\u{2019}]re|we['\u{2019}]re|it['\u{2019}]s) \(owned) [a-z]+\\b(?! (?:is|are|was|were|and|or|but|to|for|of|in|on|at|with|by|from|as|than|so|that|if|when|because)\\b)", options: [.caseInsensitive])
    static let ownerForm = ["you're": "your", "they're": "their", "we're": "our", "it's": "its"]

    static func patternIssues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = Splices.issues(text) + Advanced.subjunctiveIssues(text) + Advanced.hyphenIssues(text)
        for i in Agreement.issues(text) + Apostrophes.issues(text) where !out.contains(where: { $0.range.overlaps(i.range) }) { out.append(i) }
        for m in meAnd.matches(in: text, range: full) {
            let raw = ns.substring(with: m.range(at: 2)); let name = raw.prefix(1).uppercased() + raw.dropFirst()
            out.append(Issue(range: m.range(at: 1), kind: .grammar, message: "Use \"\(name) and I\" as the subject",
                             replacements: ["\(name) and I"], original: ns.substring(with: m.range(at: 1))))
        }
        for m in andMe.matches(in: text, range: full) {
            let name = ns.substring(with: m.range(at: 1)).components(separatedBy: " and ")[0]
            let subject = ["me": "I", "him": "he", "her": "she", "us": "we", "them": "they"][ns.substring(with: m.range(at: 2))] ?? "I"
            out.append(Issue(range: m.range(at: 1), kind: .grammar, message: "Use \"\(name) and \(subject)\" as the subject",
                             replacements: ["\(name) and \(subject)"], original: ns.substring(with: m.range(at: 1))))
        }
        for m in andI.matches(in: text, range: full) {
            let before = ns.substring(with: m.range(at: 1))
            let pronoun = ns.substring(with: m.range(at: 3))
            guard prepositions.contains(before.lowercased()) || !clauseVerbs.contains(before.lowercased()) && isVerb(at: m.range(at: 1).location, in: text),
                  let fix = objectForm[pronoun] else { continue }
            let span = NSRange(location: m.range(at: 2).location, length: NSMaxRange(m.range(at: 3)) - m.range(at: 2).location)
            let pair = ns.substring(with: m.range(at: 2)) + fix
            out.append(Issue(range: span, kind: .grammar, message: "After \u{201C}\(before)\u{201D} the pronoun is \u{201C}\(fix)\u{201D}: \u{201C}\(pair)\u{201D}.",
                             replacements: [pair], original: ns.substring(with: span)))
        }
        for m in objectSubject.matches(in: text, range: full) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let word = ns.substring(with: r)
            guard let fix = subjectForm[word], !out.contains(where: { $0.range.overlaps(r) }) else { continue }
            out.append(Issue(range: r, kind: .grammar, message: "As the subject the pronoun is \u{201C}\(fix)\u{201D}.",
                             replacements: [fix], original: word))
        }
        for m in loneSubject.matches(in: text, range: full) {
            let before = ns.substring(with: m.range(at: 1)).lowercased()
            let r = m.range(at: 2)
            let pronoun = ns.substring(with: r)
            // "for he was tired" and "after we left" are clauses; a verb that takes a clause ("said he", "knew they")
            // or a helper ("did they", "will we") is not an object slot.
            let takesObject = prepositions.contains(before) && !["after", "before", "except", "including"].contains(before)
                || !clauseVerbs.contains(before) && !Splices.auxiliaries.contains(before) && !Splices.reporting.contains(before)
                    && before != "let" && isVerb(at: m.range(at: 1).location, in: text)
            guard takesObject, let fix = objectForm[pronoun], !out.contains(where: { $0.range.overlaps(r) }) else { continue }
            out.append(Issue(range: r, kind: .grammar, message: "After \u{201C}\(before)\u{201D} the pronoun is \u{201C}\(fix)\u{201D}.",
                             replacements: [fix], original: pronoun))
        }
        for m in tooTwo.matches(in: text, range: full) where isPluralNoun(at: m.range(at: 2).location, in: text) {
            let r = m.range(at: 1), word = ns.substring(with: r)
            let fix = word.first == "T" ? "Two" : "two"
            out.append(Issue(range: r, kind: .grammar, message: "The number is \u{201C}\(fix)\u{201D}.", replacements: [fix], original: word))
        }
        for m in twoToo.matches(in: text, range: full) {
            let r = m.range(at: 1), word = ns.substring(with: r)
            let fix = word.first == "T" ? "Too" : "too"
            out.append(Issue(range: r, kind: .grammar, message: "More than enough is \u{201C}\(fix)\u{201D}.", replacements: [fix], original: word))
        }
        for m in missingTo.matches(in: text, range: full) where !out.contains(where: { $0.range.overlaps(m.range(at: 1)) }) {
            let r = m.range(at: 1), verb = ns.substring(with: r)
            guard !notBare.contains(verb), isPlainVerb(at: r.location, in: text) else { continue }
            out.append(Issue(range: r, kind: .grammar, message: "This verb needs \u{201C}to\u{201D} before it: \u{201C}to \(verb)\u{201D}.",
                             replacements: ["to " + verb], original: verb))
        }
        let singular = ["have": "has", "are": "is", "were": "was", "do": "does", "don't": "doesn't"]
        for m in eachHave.matches(in: text, range: full) where !out.contains(where: { $0.range.overlaps(m.range(at: 1)) }) {
            let v = ns.substring(with: m.range(at: 1))
            out.append(Issue(range: m.range(at: 1), kind: .grammar, message: "\"Each\" takes a singular verb",
                             replacements: [singular[v.lowercased()] ?? v], original: v))
        }
        for m in contractedOwner.matches(in: text, range: full) {
            let r = m.range(at: 1)
            let word = ns.substring(with: r)
            guard var fix = ownerForm[word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")] else { continue }
            if word.first?.isUppercase == true { fix = fix.prefix(1).uppercased() + fix.dropFirst() }
            out.append(Issue(range: r, kind: .grammar, message: "Something is owned here: \u{201C}\(fix)\u{201D}.",
                             replacements: [fix], original: word))
        }
        for m in collocationRegex.matches(in: text, range: full) {
            let phrase = ns.substring(with: m.range)
            let words = phrase.split(separator: " ").map(String.init)
            guard let last = words.last, let c = collocations.first(where: { phrase.lowercased().hasPrefix($0.0 + " ") && $0.1.contains(last.lowercased()) }) else { continue }
            let wrongR = NSRange(location: NSMaxRange(m.range) - (last as NSString).length, length: (last as NSString).length)
            // "entitled a receipt" is missing "to"; the others swap the word.
            let rep = c.0 == "entitled" ? c.2 + " " + last : c.2
            let head = words.dropLast().joined(separator: " ")
            out.append(Issue(range: wrongR, kind: .grammar, message: "\u{201C}\(head)\u{201D} takes \u{201C}\(c.2)\u{201D}: \u{201C}\(head) \(rep)\u{201D}.",
                             replacements: [rep], original: last))
        }
        return out
    }

    /// Whether the word at `loc` is a verb in its plain form ("collect", not "collects", "collected" or "collecting").
    static func isPlainVerb(at loc: Int, in text: String) -> Bool {
        guard let r = Range(NSRange(location: loc, length: 0), in: text) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let (tag, wr) = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass)
        let w = text[wr].lowercased()
        guard tag == .verb, !w.hasSuffix("ing"), !w.hasSuffix("ed") || w.hasSuffix("eed"),
              let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue else { return false }
        return lemma.lowercased() == w
    }

    /// Whether the word at `loc` is a plural noun in its sentence: tagged a noun, and its lemma is not the word itself.
    static func isPluralNoun(at loc: Int, in text: String) -> Bool {
        guard let r = Range(NSRange(location: loc, length: 0), in: text) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let (tag, wr) = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass)
        guard tag == .noun, let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue else { return false }
        return lemma.lowercased() != text[wr].lowercased()
    }

    /// Whether the word at `loc` reads as a verb in its sentence ("invited Maya and I"), not a noun ("the buyer and I").
    static func isVerb(at loc: Int, in text: String) -> Bool {
        guard let r = Range(NSRange(location: loc, length: 0), in: text) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        return tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0 == .verb
    }

    /// Flags sentences that came through in another language (voice typing can switch languages mid-sentence).
    static func languageIssues(_ text: String) -> [Issue] {
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, r, _, _ in
            guard let s, s.split(separator: " ").count >= 4 else { return }
            let rec = NLLanguageRecognizer()
            rec.languageConstraints = [.english, .spanish, .french, .portuguese, .italian, .german]
            rec.processString(s)
            guard let (lang, p) = rec.languageHypotheses(withMaximum: 1).first, lang != .english, p > 0.85 else { return }
            let name = Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsr = (text as NSString).range(of: trimmed, range: NSRange(r, in: text))
            out.append(Issue(range: nsr, kind: .voice, message: "This came through in \(name). Translate to English?",
                             replacements: [], original: trimmed))
        }
        return out
    }
}
