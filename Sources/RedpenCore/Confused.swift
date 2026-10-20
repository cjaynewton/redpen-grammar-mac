import Foundation
import NaturalLanguage

/// Mixed-up words that the words around them settle without a model: "your able to", "please advice us",
/// "check weather the", "feels lose", "over their by the door". Each pattern is a spot where only one of the pair
/// fits as grammar, so these work on every Mac, with or without Apple's model. Plain code, no model.
enum Confused {
    struct Pattern {
        let regex: NSRegularExpression
        let fix: String  // the right word, in lowercase
        init(_ pattern: String, _ fix: String) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.fix = fix
        }
    }

    static let objects = "(?:us|me|him|her|them|you|it|the|our|your|their|his|my|a|an|this|that|these|those|whether|if|on|against)"
    static let owners = "(?:the|a|an|my|our|your|his|her|their|its|this|that|some|any|no|good|expert|legal|professional|free|sound|bad|helpful|useful|practical)"

    /// Group 1 is always the wrong word.
    static let patterns: [Pattern] = [
        // "your able to", "your welcome to": a describing word, not a thing owned. "Your right to" is a thing.
        Pattern("\\b(your) (?:able|welcome|ready|sure|aware|going|coming|being|not|unable|free|allowed|supposed|likely|unlikely)\\b(?= (?:to|for|at|in|on|with)\\b|\\s*[.,!?;:]|$)", "you're"),
        // "Please advice us", "can advice the team": a verb is wanted.
        Pattern("\\b(?:please|will|would|can|could|should|must|might|may|to|n't|not) (advice) \(objects)\\b", "advise"),
        // "your advise before", "for advise on": a thing is wanted.
        Pattern("\\b\(owners) (advise)(?=\\s*[.,!?;:]|$| (?:on|about|from|before|is|was|and|or|but|to|for)\\b)", "advice"),
        // "check weather the new starter can": a question about yes or no.
        Pattern("\\b(?:check|checking|checked|ask|asking|asked|know|knowing|see|decide|deciding|decided|wonder|wondering|wondered|confirm|confirming|confirmed|determine|tell me|let me know|unsure|not sure|find out|found out|whether or not) (weather) (?:the|we|you|they|he|she|it|i|our|your|their|this|that|there|anyone|someone|any|all)\\b", "whether"),
        // "feels lose", "came lose": not tight.
        Pattern("\\b(?:feel|feels|felt|feeling|seem|seems|seemed|come|comes|came|coming|get|gets|got|getting|work|works|worked|working|break|breaks|broke|cut|let|hang|hangs|hanging|is|are|was|were|be|been|become|becomes|became|too|very|bit|slightly) (lose)\\b(?=\\s*[.,!?;:]|$| (?:and|or|but|on|at|in|from|again|now|so)\\b)", "loose"),
        // "We can except applications": a verb meaning take.
        Pattern("\\b(?:can|cannot|can't|will|won't|would|could|please|not|n't|gladly|happily|to) (except) (?:the|a|an|your|our|their|this|that|these|those|it|them|any|all|applications|payment|payments|cash|cards|returns|orders|bookings|deliveries|responsibility|liability|delivery)\\b", "accept"),
        // "over their by the toolbox": a place, not an owner.
        Pattern("\\b(?:over|in|out|up|down|from|right|back|go|get|stay|sit|wait) (their)(?=\\s*[.,!?;:]|$| (?:by|beside|until|till|on|in|at|for|now|today|tomorrow|tonight|and|too|again|already|yet|before|after|next|near|with)\\b)", "there"),
        // "leave the key hear beside the meter", "come hear": a place.
        Pattern("\\b(?:come|stay|wait|sit|stand|right|from|get|over|back|up|down|in|out|key|keys|it|them) (hear)(?= (?:beside|by|next|on|in|at|until|till|with|before|after|now|today|tomorrow)\\b|\\s*[.,!?;:]|$)", "here"),
        // "the likely affect of", "no affect on": the result.
        Pattern("\\b(?:the|an|any|no|this|that|its|their|our|your|likely|positive|negative|big|small|main|net|side|real|full|same|knock-on|lasting|little) (affect) (?:of|on|this|that)\\b", "effect"),
        // "plane paper bags": simple, unpatterned.
        Pattern("\\b(plane) (?:paper|text|english|language|sight|view|clothes|white|black|yogurt|yoghurt|flour|truth|speech|wrapping|bag|bags|envelope|envelopes|background|cardboard|packaging|labels?|fabric|cotton|wood|design|t-shirts?|shirts?)\\b", "plain"),
        // "a nice complement about the team": praise.
        Pattern("\\b(complements?) (?:about|on) (?:our|your|their|the|my|his|her|its)\\b", "compliment"),
        // "stay stationery", "remained stationery": not moving.
        Pattern("\\b(?:stay|stays|stayed|staying|remain|remains|remained|remaining|stand|stood|is|was|are|were|be|been|completely|perfectly) (stationery)\\b", "stationary"),
    ]

    // "leave there coats in the cupboard", "put there collection notes in": a verb that moves a thing, then "there"
    // and a noun that the verb acts on. "left there years ago" and "put there yesterday" are places and times.
    static let thereOwner = try! NSRegularExpression(pattern:
        "\\b(?:put|puts|leave|leaves|left|bring|brings|brought|take|takes|took|send|sends|keep|keeps|kept|store|stores|stored|place|places|placed|return|returns|returned|pack|packs|packed|collect|collects|collected|update|updates|updated|sign|signs|hand|hands|handed|drop|drops|dropped|share|shares|shared|check|checks|checked|fill|fills|filled|label|labels|labelled|labeled) (there) ([a-z]+) ([a-z]+)\\b", options: [.caseInsensitive])

    /// Whether the word reads as a noun on its own, in "I saw the ___ today." After "there" the tagger takes most
    /// words for verbs ("there coats").
    static func isNoun(_ w: String) -> Bool {
        let s = "I saw the \(w) today."
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        guard let r = s.range(of: " \(w) ") else { return false }
        return tagger.tag(at: s.index(after: r.lowerBound), unit: .word, scheme: .lexicalClass).0 == .noun
    }

    static func issues(_ text: String) -> [Issue] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = []
        for m in thereOwner.matches(in: text, range: full) {
            let noun = ns.substring(with: m.range(at: 2)).lowercased()
            guard !Agreement.amounts.contains(noun), !Apostrophes.timeNouns.contains(noun), !Splices.auxiliaries.contains(noun),
                  isNoun(noun), isNoun(ns.substring(with: m.range(at: 3)).lowercased())
                      || Rules.prepositions.contains(ns.substring(with: m.range(at: 3)).lowercased())
            else { continue }
            let r = m.range(at: 1), word = ns.substring(with: r)
            let fix = word.first?.isUppercase == true ? "Their" : "their"
            out.append(Issue(range: r, kind: .grammar, message: "Commonly confused: did you mean \u{201C}\(fix)\u{201D}?",
                             replacements: [fix], original: word))
        }
        for p in patterns {
            for m in p.regex.matches(in: text, range: full) {
                let r = m.range(at: 1), word = ns.substring(with: r)
                var fix = p.fix
                if word.lowercased() == "complements" { fix = "compliments" }
                if word.first?.isUppercase == true { fix = fix.prefix(1).uppercased() + fix.dropFirst() }
                guard !out.contains(where: { $0.range.overlaps(r) }) else { continue }
                out.append(Issue(range: r, kind: .grammar, message: "Commonly confused: did you mean \u{201C}\(fix)\u{201D}?",
                                 replacements: [fix], original: word))
            }
        }
        return out
    }
}
