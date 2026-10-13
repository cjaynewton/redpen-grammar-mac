import Foundation
import NaturalLanguage

/// A short, plain explanation for a fix, so the card teaches the rule instead of only fixing the word.
/// Lessons are written by hand, never generated: a wrong explanation teaches the wrong rule.
public struct Lesson: Sendable, Equatable {
    public let id: String      // stable, used to count repeats ("your-youre", "spell-definitely")
    public let title: String   // what the pattern is called in the patterns page
    public let rule: String    // one plain sentence
    public let example: String
}

public enum Lessons {
    static func make(_ id: String, _ title: String, _ rule: String, _ example: String) -> Lesson {
        Lesson(id: id, title: title, rule: rule, example: example)
    }

    /// Word pairs that share one lesson, matched on the flagged word and the suggested word (lowercased).
    static let pairs: [(Set<String>, Lesson)] = [
        (["your", "you're", "youre"], make("your-youre", "your / you're",
            "\u{201C}You're\u{201D} means \u{201C}you are.\u{201D} \u{201C}Your\u{201D} owns something. Say \u{201C}you are\u{201D} out loud; if it fits, write you're.",
            "You're sending your PO today.")),
        (["their", "there", "they're", "theyre"], make("their-there", "their / there / they're",
            "\u{201C}They're\u{201D} means \u{201C}they are.\u{201D} \u{201C}Their\u{201D} owns something. \u{201C}There\u{201D} is a place, or starts \u{201C}there is.\u{201D}",
            "They're moving their display over there.")),
        (["its", "it's"], make("its-its", "its / it's",
            "\u{201C}It's\u{201D} only ever means \u{201C}it is\u{201D} or \u{201C}it has.\u{201D} \u{201C}Its\u{201D} owns something, like \u{201C}his.\u{201D}",
            "It's the brand's best month; its sales doubled.")),
        (["then", "than"], make("then-than", "then / than",
            "\u{201C}Than\u{201D} compares two things. \u{201C}Then\u{201D} is about time, what happens next.",
            "Sales were higher than last year, then they dropped.")),
        (["affect", "effect", "affects", "effects", "affected", "effected"], make("affect-effect", "affect / effect",
            "\u{201C}Affect\u{201D} is the action (to change something). \u{201C}Effect\u{201D} is the result. A for action, E for end result.",
            "The price change will affect volume. The effect was small.")),
        (["lose", "loose"], make("lose-loose", "lose / loose",
            "\u{201C}Lose\u{201D} means to no longer have. \u{201C}Loose\u{201D} means not tight. Loose has room for an extra o.",
            "We can't lose this account over a loose pallet wrap.")),
        (["whose", "who's"], make("whose-whos", "whose / who's",
            "\u{201C}Who's\u{201D} means \u{201C}who is.\u{201D} \u{201C}Whose\u{201D} asks who owns something.",
            "Who's calling the retailer whose terms we accepted?")),
        (["of", "have", "'ve"], make("could-have", "could have, not could of",
            "\u{201C}Could of\u{201D} is how \u{201C}could've\u{201D} sounds. It is always could have, should have, would have.",
            "We should have shipped on Monday.")),
        (["a", "an"], make("a-an", "a / an",
            "Use \u{201C}an\u{201D} before a vowel sound and \u{201C}a\u{201D} before a consonant sound. It's the sound, not the letter.",
            "An hour, a unit, an SKU.")),
        (["past", "passed"], make("past-passed", "past / passed",
            "\u{201C}Passed\u{201D} is the verb (it passed the review). \u{201C}Past\u{201D} is a time or means beyond (walked past).",
            "The brand passed the line review; the past year was hard.")),
        (["further", "farther"], make("further-farther", "further / farther",
            "\u{201C}Farther\u{201D} is physical distance. \u{201C}Further\u{201D} means more, or to a greater degree.",
            "The display was farther from the entrance; we need to talk further.")),
        (["alot", "a lot"], make("a-lot", "a lot",
            "\u{201C}A lot\u{201D} is always two words, like \u{201C}a little.\u{201D}",
            "We sold a lot of units.")),
        (["could care less", "couldn't care less"], make("couldnt-care-less", "couldn't care less",
            "The phrase is \u{201C}couldn't care less\u{201D}: you care so little there is no less to give.",
            "I couldn't care less about the endcap fee.")),
    ]

    /// Subject pronouns versus object pronouns.
    static let pronounCase = make("pronoun-case", "I / me, he / him",
        "Use I, he, she, we, they when doing the action; me, him, her, us, them after a verb or a word like \u{201C}between.\u{201D} Drop the other person to test it: \u{201C}me agreed\u{201D} sounds wrong.",
        "The buyer and I agreed. Between you and me, it's not closed.")
    static let pronouns: Set<String> = ["i", "me", "he", "him", "she", "her", "we", "us", "they", "them"]

    static let agreement = make("agreement", "verb agrees with its subject",
        "The verb matches who is doing it. One thing takes was, has, is, doesn't; more than one takes were, have, are, don't. Each, neither and one of take the single form.",
        "The pallets were stacked. Neither sample was approved. She doesn't want to.")
    static let agreementWords: Set<String> = ["was", "were", "is", "are", "has", "have", "do", "does", "don't", "doesn't",
                                             "pay", "pays", "show", "shows", "want", "wants"]

    static let tense = make("verb-form", "verb form",
        "Use the past form for things that already happened, and the -en form after has, have, had, was or were.",
        "Yesterday we went to the show. The report was written by the category manager. I saw the display.")

    static let fewer = make("less-fewer", "less / fewer",
        "Fewer is for things you can count (fewer brands, fewer units). Less is for amounts you can't (less space, less time).",
        "Fewer retailers took the line, so we had less shelf space.")

    static let doubleNegative = make("double-negative", "double negative",
        "Two negatives cancel out. Keep one: doesn't have any, or has no.",
        "The brand has no shelf space left. The brand doesn't have any left.")

    static let splice = make("comma-splice", "comma splice",
        "A comma can't join two full sentences. Use a period, or keep the comma and add and, but or so.",
        "The buyer liked the pitch. He asked for a second meeting.")

    static let dangling = make("dangling-modifier", "dangling modifier",
        "An opening phrase like \u{201C}Walking into the store,\u{201D} describes whoever comes right after the comma. Put the person who did it there.",
        "Walking into the store, I saw the shelves were empty.")
    static let subjunctive = make("subjunctive", "if I were / requires that he sign",
        "For something that isn't true, or something required, use \u{201C}were\u{201D} and the plain verb.",
        "If I were the buyer\u{2026} / The contract requires that he sign.")
    static let hyphen = make("compound-modifier", "a two-year contract",
        "Two words that describe a noun together take a hyphen. After the noun they don't.",
        "a two-year contract / the contract runs two years")
    static let canadian = make("canadian-spelling", "Canadian spelling",
        "Canadian English keeps the British -our and -re (colour, centre, defence) but uses -ize (organize, realize).",
        "The colour of the centre display.")
    static let compound = make("compound-word", "one word or two",
        "One word is the thing (the setup, a login, the backup). Two words is the action (set up the display, log in, back up the file).",
        "Set up the booth before the setup inspection.")

    // House-style rules: these teach the chosen style, not grammar.
    static let dash = make("rule-dash", "house style: no dashes",
        "House style: no dashes. A period lets the pause land; a comma keeps the sentence moving.",
        "The buyer walked past the display. Twice.")
    static let colon = make("rule-colon", "house style: colons",
        "House style: colons only for labels and lists. If the colon joins two thoughts, a period is stronger.",
        "Capital deployed: $400K (fine). The answer was simple. They never reordered.")
    static let container = make("rule-container", "house style: container words",
        "House style: words like framework or ecosystem sound like thinking but carry nothing. Name the concrete thing.",
        "Not \u{201C}the retail ecosystem\u{201D} but \u{201C}the buyer, the broker and the distributor.\u{201D}")
    static let defensive = make("rule-defensive", "house style: no disclaimers",
        "House style: a disclaimer makes the reader wonder why you needed it. Cut it and let the evidence speak.",
        "Not \u{201C}nobody is lying here\u{201D}; just lay out what happened.")
    static let language = make("rule-language", "another language",
        "This sentence came through in another language, which happens with voice typing. Redpen offers the English version.",
        "")

    /// Memory tricks for words that get misspelled often. Anything else gets a plain "spelled X" lesson.
    static let tricks: [String: String] = [
        "definitely": "Hide the word \u{201C}finite\u{201D} inside: de-FINITE-ly.",
        "separate": "There's \u{201C}a rat\u{201D} in sep-A-RAT-e.",
        "accommodate": "It's big enough for two c's and two m's.",
        "necessary": "One collar, two sleeves: one c, two s's.",
        "receive": "I before e, except after c: rec-EI-ve.",
        "believe": "Never be-LIE-ve a lie.",
        "government": "Govern + ment. Keep the n.",
        "noticeable": "Notice + able. Keep the e so the c stays soft.",
        "persistent": "Ends in -ent, like \u{201C}consistent.\u{201D}",
        "recommend": "Re + commend: one c, two m's.",
        "committee": "Double m, double t, double e.",
        "occurrence": "Double c, double r, ends -ence.",
        "embarrass": "Two r's and two s's: you go really red and smile shyly.",
        "amount": "One m: a + mount.",
        "until": "One l at the end, unlike \u{201C}till.\u{201D}",
        "distributor": "Ends in -or, like \u{201C}contributor.\u{201D}",
        "argument": "Argue drops its e: argument.",
        "calendar": "Ends in -dar, like a radar.",
        "beginning": "Double the n before -ing: begin-ning.",
        "business": "Bus + i + ness: there's a bus in business.",
        "tomorrow": "One m, two r's.",
        "weird": "Weird breaks the i-before-e rule; it's weird.",
        "a lot": "Always two words.",
        "privilege": "No d: privi-lege.",
        "inventory": "Invent + ory.",
        "guarantee": "Starts with gu-, like guard.",
        "category": "Cat + e + gory: the middle letter is e.",
        "liaison": "Two i's around the a: li-A-ison.",
    ]

    /// The lesson for an issue, or nil when there is no lesson written for it.
    public static func lesson(for issue: Issue) -> Lesson? {
        let original = issue.original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let replacement = (issue.replacements.first ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let msg = issue.message.lowercased()

        switch issue.kind {
        case .voice:
            if msg.contains("em dash") || msg.contains("dashes") { return dash }
            if msg.contains("colon") { return colon }
            if msg.contains("container word") { return container }
            if msg.contains("disclaimer") { return defensive }
            if msg.hasPrefix("this came through in") { return language }
            return nil
        case .spelling:
            guard !replacement.isEmpty else { return nil }
            if msg.hasPrefix("canadian spelling") { return canadian }
            if replacement == "a lot" { return pairs.first { $0.1.id == "a-lot" }?.1 }
            let trick = tricks[replacement] ?? "Spelled \u{201C}\(replacement)\u{201D}."
            return make("spell-\(replacement)", "spelling \u{201C}\(replacement)\u{201D}", trick, "")
        case .grammar:
            break
        }

        if msg.contains("two sentences joined by a comma") { return splice }
        if msg.contains("double negative") { return doubleNegative }
        if msg.hasPrefix("dangling modifier") { return dangling }
        if msg.contains("isn't true") || msg.contains("plain verb") { return subjunctive }
        if msg.contains("take a hyphen") || msg.contains("missing hyphen") { return hyphen }
        if (original == "less" && replacement == "fewer") { return fewer }
        if Confusables.compounds.contains(where: { [$0.0, $0.1].contains(original) && [$0.0, $0.1].contains(replacement) }) { return compound }
        if msg.contains("one word") || msg.contains("two words") { return compound }
        if msg.contains("needs a verb") { return pairs.first { $0.1.id == "past-passed" }?.1 }
        if original.contains("could care less") { return pairs.first { $0.1.id == "couldnt-care-less" }?.1 }
        if original == "of", ["have", "'ve", "could have", "should have", "would have"].contains(replacement) || msg.contains("have") {
            return pairs.first { $0.1.id == "could-have" }?.1
        }

        // Pronoun case: "Me and the buyer" -> "The buyer and I", "Him" -> "He", "between you and I".
        let oWords = Set(original.split(separator: " ").map(String.init))
        let rWords = Set(replacement.split(separator: " ").map(String.init))
        if !oWords.symmetricDifference(rWords).isEmpty, oWords.symmetricDifference(rWords).isSubset(of: pronouns) {
            return pronounCase
        }

        for (words, lesson) in pairs where lesson.id != "could-have" && lesson.id != "a-lot" {
            if words.contains(original) && words.contains(replacement) && original != replacement { return lesson }
        }

        if let pair = Confusables.lookup[original], pair.contains(replacement) {
            return confusedLesson(original, replacement)
        }

        if agreementWords.contains(original) && agreementWords.contains(replacement) { return agreement }
        if sameVerb(original, replacement) { return tense }

        // Multi-word fixes ("higher then" -> "higher than", "seen" -> "have seen"): teach the one word that changed.
        let oList = original.split(separator: " ").map(String.init), rList = replacement.split(separator: " ").map(String.init)
        let removed = oList.filter { !rList.contains($0) }, added = rList.filter { !oList.contains($0) }
        if removed.count == 1, added.count == 1, oList.count > 1 || rList.count > 1 {
            var inner = issue
            inner.original = removed[0]; inner.replacements = [added[0]]
            if let l = lesson(for: inner) { return l }
        }
        if removed.isEmpty, added.count == 1, ["have", "has", "had", "was", "were", "been"].contains(added[0]) { return tense }

        // A one-word fix that is a near-miss spelling ("distributer" -> "distributor").
        if oList.count == 1, rList.count == 1, original.count > 4, editDistance(original, replacement) <= 2 {
            return make("spell-\(replacement)", "spelling \u{201C}\(replacement)\u{201D}",
                        tricks[replacement] ?? "Spelled \u{201C}\(replacement)\u{201D}.", "")
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]; row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// Fixed lessons by id, for the patterns page. Spelling and confused-pair lessons are rebuilt from the id.
    public static func byID(_ id: String) -> Lesson? {
        let fixed = pairs.map(\.1) + [pronounCase, agreement, tense, fewer, doubleNegative, splice, canadian, dangling, subjunctive, hyphen, compound, dash, colon, container, defensive, language]
        if let l = fixed.first(where: { $0.id == id }) { return l }
        if id.hasPrefix("spell-") {
            let w = String(id.dropFirst(6))
            return make(id, "spelling \u{201C}\(w)\u{201D}", tricks[w] ?? "Spelled \u{201C}\(w)\u{201D}.", "")
        }
        if id.hasPrefix("confused-") {
            let parts = id.dropFirst(9).split(separator: "-").map(String.init)
            if parts.count == 2 { return confusedLesson(parts[0], parts[1]) }
        }
        return nil
    }

    /// A lesson for a commonly confused pair, built from the meaning glosses ("compliment" = praise).
    static func confusedLesson(_ a: String, _ b: String) -> Lesson {
        let pair = [a, b].sorted()
        let lines = pair.map { w in Confusables.gloss[w].map { "\u{201C}\(w)\u{201D} means \($0)." } ?? "" }
        return make("confused-\(pair.joined(separator: "-"))", pair.joined(separator: " / "),
                    lines.joined(separator: " "), "")
    }

    /// Two forms of the same verb ("go" and "went", "wrote" and "written").
    static func sameVerb(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty, a != b, !a.contains(" "), !b.contains(" ") else { return false }
        func lemma(_ w: String) -> String? {
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = "they \(w)"
            let idx = tagger.string!.index(tagger.string!.startIndex, offsetBy: 5)
            return tagger.tag(at: idx, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
        }
        guard let la = lemma(a), let lb = lemma(b) else { return false }
        return la == lb
    }
}
