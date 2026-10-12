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
    static func isName(_ word: String, at loc: Int, in ns: NSString) -> Bool {
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

    @MainActor public static func learn(_ word: String) { NSSpellChecker.shared.learnWord(word) }
}
