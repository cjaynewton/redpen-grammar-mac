import AppKit
import NaturalLanguage

/// The Mac's own spelling and grammar checker. Instant, free, offline.
public enum Spelling {
    @MainActor
    public static func check(_ text: String) -> [Issue] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        let results = checker.check(text, range: NSRange(location: 0, length: ns.length), types: types,
                                    options: [:], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        var out: [Issue] = []
        for r in results {
            if r.resultType == .spelling {
                let word = ns.substring(with: r.range)
                if isName(word, at: r.range.location, in: ns) || acceptedElsewhere(word, checker) { continue }
                let guesses = checker.guesses(forWordRange: r.range, in: text, language: "en", inSpellDocumentWithTag: 0) ?? []
                // "ultrapure" -> "ultra pure", "sportsbook" -> "sports book": a real compound the dictionary
                // splits, not a typo. Every letter is already in the right place.
                if let g = guesses.first, isSplit(g, of: word) { continue }
                out.append(Issue(range: r.range, kind: .spelling, message: guesses.isEmpty ? "Not in the dictionary" : "Did you mean \u{201C}\(guesses[0])\u{201D}?",
                                 replacements: Array(guesses.prefix(3)), original: word))
            } else if r.resultType == .grammar, let details = r.grammarDetails {
                for d in details {
                    guard let v = d[NSGrammarRange] as? NSValue else { continue }
                    let gr = v.rangeValue.shifted(by: r.range.location)
                    let msg = (d[NSGrammarUserDescription] as? String) ?? "Grammar"
                    let corr = (d[NSGrammarCorrections] as? [String]) ?? []
                    out.append(Issue(range: gr, kind: .grammar, message: msg,
                                     replacements: Array(corr.prefix(3)), original: ns.substring(with: gr)))
                }
            }
        }
        return out
    }

    /// A capitalised word in the middle of a sentence is almost always a name (Pogacar, Sowell, Gangnam).
    /// Dictionaries miss most names, so only words at the start of a sentence are spell-checked when capitalised.
    public static func isName(_ word: String, at loc: Int, in ns: NSString) -> Bool {
        guard let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) else { return false }
        var i = loc - 1
        while i >= 0, let c = UnicodeScalar(ns.character(at: i)), CharacterSet.whitespaces.contains(c) { i -= 1 }
        let prev = i >= 0 ? UnicodeScalar(ns.character(at: i)) : nil
        if let prev, !".!?:\n\u{201C}\"(".unicodeScalars.contains(prev) { return true }
        // At the start of a sentence, ask the tagger whether the word reads as a name ("Chapek was named").
        let sentence = ns.substring(from: loc)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        let tag = tagger.tag(at: sentence.startIndex, unit: .word, scheme: .nameType).0
        if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) { return true }
        // "Loblaw's president": a possessive at the start of a sentence is nearly always a name.
        return word.hasSuffix("'s") || word.hasSuffix("\u{2019}s")
    }

    /// American, Canadian and British spellings are all accepted (behavior, neighbourhood).
    @MainActor static func acceptedElsewhere(_ word: String, _ checker: NSSpellChecker) -> Bool {
        for lang in ["en_US", "en_CA", "en_GB"] {
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return true }
        }
        return false
    }

    public static let dialectNames = ["en_CA": "Canadian", "en_US": "American", "en_GB": "British"]

    /// Words spelled for another English when the writer has picked one ("color" in Canadian English).
    /// Only words another English accepts: plain typos are left to `check`.
    @MainActor
    public static func dialect(_ text: String, _ lang: String) -> [Issue] {
        guard let name = dialectNames[lang] else { return [] }
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var out: [Issue] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { w, wr, _, _ in
            guard let w, w.count >= 3, w.allSatisfy({ $0.isLetter }) else { return }
            let r = NSRange(wr, in: text)
            if isName(w, at: r.location, in: ns) { return }
            func ok(_ s: String, _ l: String) -> Bool {
                checker.checkSpelling(of: s, startingAt: 0, language: l, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
            guard !ok(w, lang), dialectNames.keys.contains(where: { $0 != lang && ok(w, $0) }) else { return }
            guard let fix = dialectFix(w, lang, ok) else { return }
            out.append(Issue(range: r, kind: .spelling, message: "\(name) spelling: \u{201C}\(fix)\u{201D}.",
                             replacements: [fix], original: w))
        }
        return out
    }

    /// The same word in the chosen English: color -> colour, center -> centre, defense -> defence.
    static func dialectFix(_ w: String, _ lang: String, _ ok: (String, String) -> Bool) -> String? {
        let lower = w.lowercased()
        var c: [String] = []
        func swap(_ a: String, _ b: String) {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: a, range: search) {
                c.append(lower.replacingCharacters(in: r, with: b)); search = r.upperBound..<lower.endIndex
            }
        }
        for (a, b) in [("our", "or"), ("or", "our"), ("re", "er"), ("er", "re"), ("ce", "se"), ("se", "ce"), ("ize", "ise"),
                       ("ise", "ize"), ("og", "ogue"), ("ogue", "og"), ("check", "cheque"), ("cheque", "check"), ("ll", "l"), ("l", "ll"), ("ae", "e"), ("oe", "e")] { swap(a, b) }
        // Spelling swaps first (they can move three letters: check -> cheque), then the dictionary's guesses.
        if let fix = c.first(where: { $0 != lower && ok($0, lang) }) {
            return w.first?.isUppercase == true ? fix.prefix(1).uppercased() + fix.dropFirst() : fix
        }
        c = []
        c += NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (lower as NSString).length), in: lower,
                                           language: lang, inSpellDocumentWithTag: 0) ?? []
        guard let fix = c.first(where: { $0 != lower && !$0.contains(" ") && !$0.contains("-") && ok($0, lang) && Lessons.editDistance($0, lower) <= 2 }) else { return nil }
        return w.first?.isUppercase == true ? fix.prefix(1).uppercased() + fix.dropFirst() : fix
    }

    static func isSplit(_ guess: String, of word: String) -> Bool {
        let joined = guess.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return joined.caseInsensitiveCompare(word.replacingOccurrences(of: "-", with: "")) == .orderedSame
            && guess.count > word.replacingOccurrences(of: "-", with: "").count
            // Both halves must be real words of some length: "alot" -> "a lot" is still a mistake.
            && guess.split(whereSeparator: { $0 == " " || $0 == "-" }).allSatisfy { $0.count >= 3 }
    }

    /// True when the word is in the Mac dictionary as written ("their" yes, "american" no).
    @MainActor static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    @MainActor public static func learn(_ word: String) { NSSpellChecker.shared.learnWord(word) }
}

// MARK: - Sentence-aware suggestions

extension Spelling {
    /// Model picks, by sentence and misspelled word, so each sentence is asked about once.
    @MainActor static var picks: [String: String] = [:]

    /// Puts the word the sentence needs first: "I liked it, thougt it cost" wants "though", "I thougt about it"
    /// wants "thought". The dictionary's guesses are the only choices, so the model can reorder but never invent.
    /// Without Apple's model the dictionary's order stands.
    @MainActor
    public static func rank(_ issues: [Issue], in text: String) async -> [Issue] {
        var out: [Issue] = []
        for i in issues {
            guard i.kind == .spelling, let sentence = sentence(around: i.range, in: text) else { out.append(i); continue }
            let key = sentence + "|" + i.original
            if picks[key] == nil, AppleModel.isAvailable {
                let pool = candidates(for: i, in: text)
                if pool.count >= 2 { picks[key] = await AppleModel.pickWord(sentence, typo: i.original, from: pool) ?? "" }
                if picks.count > 2000 { picks.removeAll() }
            }
            out.append(applyPick(i, in: text))
        }
        return out
    }

    /// The stored pick for this issue, if any, moved to the front. Never waits on the model.
    @MainActor
    public static func applyPick(_ i: Issue, in text: String) -> Issue {
        guard i.kind == .spelling, let sentence = sentence(around: i.range, in: text),
              let pick = picks[sentence + "|" + i.original], !pick.isEmpty else { return i }
        var out = i
        out.replacements = Array(([pick] + i.replacements.filter { $0 != pick }).prefix(3))
        out.message = "Did you mean \u{201C}\(pick)\u{201D}?"
        return out
    }

    /// The issue's own suggestions plus the dictionary's, without shouting forms ("HOM" for "hom").
    @MainActor static func candidates(for i: Issue, in text: String) -> [String] {
        let more = NSSpellChecker.shared.guesses(forWordRange: i.range, in: text, language: "en", inSpellDocumentWithTag: 0) ?? []
        let lowerOriginal = i.original == i.original.lowercased()
        var seen = Set<String>()
        return (i.replacements + more).filter { c in
            if lowerOriginal, c.count > 1, c == c.uppercased() { return false }
            return seen.insert(c.lowercased()).inserted
        }.prefix(6).map { $0 }
    }

    static func sentence(around r: NSRange, in text: String) -> String? {
        let ns = text as NSString
        guard NSMaxRange(r) <= ns.length else { return nil }
        var found: String?
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, sr, _, stop in
            if NSLocationInRange(r.location, NSRange(sr, in: text)) { found = s?.trimmingCharacters(in: .whitespacesAndNewlines); stop = true }
        }
        return found
    }
}
