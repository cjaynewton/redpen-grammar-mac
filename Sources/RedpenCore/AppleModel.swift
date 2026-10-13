import Foundation
import FoundationModels
import NaturalLanguage

@Generable
struct ModelEdit {
    @Guide(description: "The wrong words, copied exactly from the input, as short as possible (one to five words)")
    var original: String
    @Guide(description: "The corrected words that replace original")
    var replacement: String
    @Guide(description: "Five words or fewer saying what was wrong, e.g. 'Subject and verb disagree'")
    var reason: String
}

@Generable
struct ModelReview {
    @Guide(description: "Only real grammar or word errors. Empty when the text is correct.")
    var edits: [ModelEdit]
}

/// Apple's on-device model. Grammar a dictionary cannot see, plus translation. Nothing leaves the Mac.
public enum AppleModel {
    static let instructions = """
    You are a careful copy editor. Find real grammar errors only: wrong verb tense or agreement, wrong word \
    (their/there, its/it's, affect/effect), wrong pronoun case, missing or doubled words. \
    Do not change style, tone, word choice that is correct, punctuation preferences, or names. \
    Do not report spelling typos. If the text is correct, return no edits.
    """

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let rewriteInstructions = """
    Correct grammar errors in the user's text: verb tense and agreement, wrong word (their/they're, its/it's, \
    affect/effect, could of), pronoun case, missing or doubled words. Keep every correct word exactly as written. \
    Do not improve style, do not change punctuation, do not fix spelling. Reply with the text only. \
    If there are no grammar errors, reply with the text unchanged.
    """

    /// Checks one paragraph by asking for a corrected copy and underlining only what changed.
    /// Ranges are relative to `paragraph`.
    /// Works one sentence at a time: on a whole paragraph the small model starts "improving" deliberate
    /// fragments ("Not sold it." became "Did not sell it.").
    public static func check(_ paragraph: String) async -> [Issue] {
        guard isAvailable else { return [] }
        var out: [Issue] = []
        var sentences: [(String, Int)] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { s, r, _, _ in
            if let s { sentences.append((s, NSRange(r, in: paragraph).location)) }
        }
        for (s, base) in sentences {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.split(separator: " ").count >= 4, hasVerb(trimmed) else { continue }
            let session = LanguageModelSession(instructions: rewriteInstructions)
            guard let fixed = try? await session.respond(to: trimmed, options: GenerationOptions(temperature: 0)).content
            else { continue }
            let all = Diff.edits(from: trimmed, to: fixed.trimmingCharacters(in: .whitespacesAndNewlines))
            // One implausible change means the model misread the sentence, so none of its changes are trusted.
            // More than two changes means it rewrote the sentence rather than corrected it.
            guard all.allSatisfy(plausible), all.count <= 2 else { continue }
            let edits = all
            let lead = (s as NSString).range(of: trimmed).location
            for e in edits where await confirmed(trimmed, e) {
                var e = e; e.range = e.range.shifted(by: base + lead); e.tentative = true; out.append(e)
            }
        }
        return out
    }

    static let judgeInstructions = """
    You judge English grammar. Both sentences may be correct; style and word choice do not count. \
    Reply A if only sentence A has a grammar error, B if only sentence B has one, or NONE if both are \
    grammatical. Reply with one word.
    """

    /// Second opinion on each change: the model sees the original and corrected sentence as A and B, in both
    /// orders, and the change stands only if it calls the original wrong both times. Cuts restyling such as
    /// "impact" to "effect" that the rewrite slips in.
    static func confirmed(_ sentence: String, _ e: Issue) async -> Bool {
        guard let rep = e.replacements.first else { return true }
        let fixed = (sentence as NSString).replacingCharacters(in: e.range, with: rep)
        func ask(_ a: String, _ b: String) async -> String? {
            let session = LanguageModelSession(instructions: judgeInstructions)
            let r = try? await session.respond(to: "A: \(a)\nB: \(b)", options: GenerationOptions(temperature: 0)).content
            return r?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        }
        if let one = await ask(sentence, fixed), one.hasPrefix("A") { return true }
        if let two = await ask(fixed, sentence), two.hasPrefix("B") { return true }
        return false
    }

    /// For dangling modifiers: whether the thing named is not a person, group or animal, so it could not have
    /// done the opening action ("the shelves" cannot be "walking into the store"). A plain question about what
    /// the thing is: the small model answers that far more reliably than "could X do Y".
    public static func cannotDo(_ subject: String, _ action: String) async -> Bool {
        guard isAvailable else { return false }
        let session = LanguageModelSession(instructions: "Answer with one word, yes or no.")
        let q = "Is \"\(subject)\" a person, a group of people (such as a team or company), or an animal?"
        guard let a = try? await session.respond(to: q, options: GenerationOptions(temperature: 0)).content else { return false }
        return a.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased().hasPrefix("no")
    }

    /// A fragment ("Different brands.") is a style choice, not an error to fix.
    static func hasVerb(_ s: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var found = false
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .verb { found = true; return false }
            return true
        }
        return found
    }

    /// Drops edits that split sentences or bring in a known error ("could of").
    static func plausible(_ e: Issue) -> Bool {
        guard let r = e.replacements.first else { return true }
        if r.contains(".") || r.contains("?") || r.contains("!") { return false }
        // Slipping in "was", "been" or "is" ("not made" -> "not been made") turns a deliberate fragment into a sentence.
        let aux: Set<String> = ["be", "been", "was", "were", "is", "are", "am"]
        let rWords = r.lowercased().split(separator: " ").map(String.init)
        let oWords = e.original.lowercased().split(separator: " ").map(String.init)
        if rWords.count == oWords.count + 1, rWords.filter({ !oWords.contains($0) }).allSatisfy({ aux.contains($0) }) { return false }
        // The model sometimes invents a phrase ("test" became "test could not be run"). A correction adds one word at most.
        if r.split(separator: " ").count - e.original.split(separator: " ").count > 1 { return false }
        // Expanding a contraction ("We're" to "We are") is style.
        let o = e.original.lowercased()
        if (o.contains("'") || o.contains("\u{2019}")) && !r.contains("'") && !r.contains("\u{2019}")
            && r.lowercased().hasPrefix(String(o.prefix(2))) { return false }
        if r.range(of: "\\b(could|should|would|must|might) of\\b", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    /// Older structured-output check, kept for comparison in the test.
    public static func checkStructured(_ paragraph: String) async -> [Issue] {
        guard isAvailable, paragraph.split(separator: " ").count >= 3 else { return [] }
        let session = LanguageModelSession(instructions: instructions)
        guard let review = try? await session.respond(to: paragraph, generating: ModelReview.self,
                                                      options: GenerationOptions(temperature: 0)).content
        else { return [] }
        let ns = paragraph as NSString
        var out: [Issue] = []
        for e in review.edits {
            let orig = e.original.trimmingCharacters(in: .whitespaces)
            let rep = e.replacement.trimmingCharacters(in: .whitespaces)
            guard !orig.isEmpty, orig.caseInsensitiveCompare(rep) != .orderedSame else { continue }
            let r = ns.range(of: orig)
            guard r.location != NSNotFound else { continue }  // model invented text: drop it
            out.append(Issue(range: r, kind: .grammar, message: e.reason, replacements: [rep], original: orig))
        }
        return out
    }

    public static func translate(_ sentence: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: "Translate the user's text into natural English. Reply with the translation only.")
        return try? await session.respond(to: sentence, options: GenerationOptions(temperature: 0)).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
