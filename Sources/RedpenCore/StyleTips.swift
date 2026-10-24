import Foundation

/// Style tips: purple underlines for writing that is correct but could be stronger. Every tip is off until the
/// writer switches it on in Settings. Each one is a plain word list or a narrow pattern, tuned on finished
/// paragraphs so a typical one is not covered in purple.
public struct StyleTip: Sendable {
    public enum Group: String, Sendable, CaseIterable {
        case clear, strong, fresh
        public var name: String { switch self { case .clear: "Clear"; case .strong: "Strong"; case .fresh: "Fresh" } }
        /// The group switch's label.
        public var motto: String {
            switch self { case .clear: "Say it plainly"; case .strong: "Sound sure of yourself"; case .fresh: "Sound like yourself" }
        }
        public var tips: [StyleTip] { StyleTip.all.filter { $0.group == self } }
    }

    public let id: String
    public let name: String
    public let group: Group
    /// Shown in purple under the tip's name in Settings.
    public let samples: [String]
    /// What the first sample becomes ("to"), shown after an arrow.
    public let becomes: String?
    /// The lesson on the fix box.
    public let message: String
    let matchers: [Matcher]

    /// One way a tip finds its words. `mark` is the capture group to underline (0 is the whole match).
    /// `fix` turns the marked words into the suggestion; `cut` removes them cleanly instead; neither is flag only.
    struct Matcher: Sendable {
        let regex: NSRegularExpression
        var mark = 0
        var fix: (@Sendable (String) -> String)? = nil
        var cut = false
    }

    public static let all: [StyleTip] = [filler, softeners, unsourced, twice, plain, passive, nominal, slowStart, apology,
                                         cliche, soundsLikeAI, promises]

    public static func find(_ id: String) -> StyleTip? { all.first { $0.id == id } }

    /// Settings files from before 0.9 call the softeners list "hedging".
    public static func migrate(_ ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids.map({ $0 == "hedging" ? "softeners" : $0 }) where !out.contains(id) { out.append(id) }
        return out
    }

    /// LanguageTool rules a switched-on tip needs. Empty when no such tip is on, so the request is unchanged.
    public static func languageToolRules(_ on: [String]) -> [String] {
        on.contains("passive") ? ["PASSIVE_VOICE"] : []
    }

    // MARK: Finding

    /// Every match of the switched-on tips, purple. Words already on the writer's own list are left to that rule.
    static func issues(_ text: String, on ids: [String], skip own: Set<String>) -> [Issue] {
        guard !ids.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Issue] = []
        for tip in all where ids.contains(tip.id) {
            for m in tip.matchers {
                for found in m.regex.matches(in: text, range: full) {
                    let r = found.range(at: m.mark)
                    guard r.location != NSNotFound, r.length > 0 else { continue }
                    let words = ns.substring(with: r)
                    if own.contains(words.lowercased()) { continue }
                    var range = r, reps: [String] = []
                    if m.cut, let c = cut(r, in: ns) { range = c.range; reps = [c.fix] }
                    else if let f = m.fix { reps = [matchCase(f(words), words)] }
                    var i = Issue(range: range, kind: .voice, message: tip.message, replacements: reps, original: ns.substring(with: range))
                    i.tip = tip.id
                    out.append(i)
                }
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// "Utilize" becomes "Use" and "UTILIZE" becomes "USE", so the fix keeps the writer's capitals.
    static func matchCase(_ fix: String, _ found: String) -> String {
        guard let f = found.first, f.isUppercase, !fix.isEmpty else { return fix }
        if found.count > 1, found == found.uppercased() { return fix.uppercased() }
        return fix.prefix(1).uppercased() + fix.dropFirst()
    }

    /// Cuts `r` and the space or commas around it, so the sentence still reads. When the cut opens a sentence,
    /// the next word is taken into the range and given its capital ("Basically, we" becomes "We").
    /// Nil when there is no clean cut; the tip is then flag only.
    static func cut(_ r: NSRange, in ns: NSString) -> (range: NSRange, fix: String)? {
        let len = ns.length
        func ch(_ i: Int) -> Character? { i >= 0 && i < len ? Character(ns.substring(with: NSRange(location: i, length: 1))) : nil }
        let end = NSMaxRange(r)
        if Engine.startsSentence(at: r.location, in: ns) {
            var j = end
            if ch(j) == "," { j += 1 }
            while let c = ch(j), c == " " { j += 1 }
            guard j > end || ch(j) == nil, let first = ch(j), first.isLetter else { return nil }
            var k = j
            while let c = ch(k), c.isLetter || c == "'" || c == "\u{2019}" { k += 1 }
            let word = ns.substring(with: NSRange(location: j, length: k - j))
            if first.isUppercase { return (NSRange(location: r.location, length: j - r.location), "") }
            return (NSRange(location: r.location, length: k - r.location), word.prefix(1).uppercased() + word.dropFirst())
        }
        guard ch(r.location - 1) == " " else { return nil }
        let after = ch(end)
        if ch(r.location - 2) == "," {
            // "was, you know, late" and "by Friday, you know?"
            if after == "," { return (NSRange(location: r.location - 2, length: r.length + 3), "") }
            if after == nil || ".?!;".contains(after!) { return (NSRange(location: r.location - 2, length: r.length + 2), "") }
            if after == " " { return (NSRange(location: r.location, length: r.length + 1), "") }
            return nil
        }
        if after == " " { return (NSRange(location: r.location - 1, length: r.length + 1), "") }
        if after == "," { return (NSRange(location: r.location - 1, length: r.length + 2), "") }
        if after == nil || ".?!;".contains(after!) { return (NSRange(location: r.location - 1, length: r.length + 1), "") }
        return nil
    }

    // MARK: Building blocks

    /// The start of a sentence: the start of a line, or after . ! or ? and a space.
    static let start = "(?:^|(?<=[.!?]\\s)|(?<=[.!?]\\s\\s)|(?<=[.!?][\"\u{201D}\u{2019}]\\s))"

    static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
    }

    /// A phrase as a whole-word pattern, either apostrophe.
    static func words(_ phrase: String) -> String {
        NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "'", with: "['\u{2019}]")
    }

    /// One matcher per phrase, each offering its shorter form (nil: flag only, "": cut it).
    static func list(_ pairs: [(String, String?)]) -> [Matcher] {
        pairs.map { phrase, fix in
            let r = re("\\b" + words(phrase) + "\\b")
            guard let fix else { return Matcher(regex: r) }
            return fix.isEmpty ? Matcher(regex: r, cut: true) : Matcher(regex: r, fix: { _ in fix })
        }
    }

    // MARK: Clear

    static let filler = StyleTip(
        id: "filler", name: "Filler words", group: .clear, samples: ["basically", "you know", "um"], becomes: nil,
        message: "Filler adds a word and takes away certainty. The sentence says the same thing without it.",
        matchers: [
            Matcher(regex: re("\\b(?:um+|uh+|erm)\\b"), cut: true),
            Matcher(regex: re("\\b(?:basically|literally)\\b"), cut: true),
            // "Actually" opening a sentence; mid-sentence it often marks a real contrast.
            Matcher(regex: re(start + "actually\\b(?=,)"), cut: true),
            // "really" only where it props up another softener ("really just", "really quite").
            Matcher(regex: re("\\breally(?= (?:just|quite|very|pretty|kind of|sort of)\\b)"), cut: true),
            // "just" only where it shrinks a request; "I just finished" means a moment ago.
            Matcher(regex: re("\\bjust(?= (?:wanted|wanting|checking|following up|wondering|a quick|a reminder|to (?:check|confirm|follow up|let you know|touch base|say))\\b)"), cut: true),
            // "you know" set off by commas, or opening a sentence; "as you know" and "do you know" stay.
            Matcher(regex: re("(?<=, )you know(?=[,.?!])|" + start + "you know(?=,)"), cut: true),
        ])

    static let softenerWords = ["I think", "I feel like", "I guess", "maybe", "perhaps", "somewhat", "it seems",
                                "to be honest"]
    static let softeners = StyleTip(
        id: "softeners", name: "Softeners", group: .clear, samples: ["I think", "sort of", "maybe"], becomes: nil,
        message: "A softener makes the point sound unsure. Say it plainly and let the reader decide.",
        matchers: [
            Matcher(regex: re("\\bI think(?! (?:about|of|so|through|back|over|twice|ahead)\\b)(?: that)?\\b"), cut: true),
            Matcher(regex: re("\\b(?:I feel like|I guess|to be honest|it seems(?: that| like)?)(?=[ ,])"), cut: true),
            Matcher(regex: re("\\b(?:maybe|perhaps|somewhat)\\b"), cut: true),
            // "kind of" and "sort of" as softeners only: "what kind of roof" and "this sort of job" are fine.
            Matcher(regex: re("(?<!\\b(?:a|an|the|what|which|this|that|these|those|any|some|every|each|one|same|other|no|our|your|my|his|her|their|its|all|right|wrong|that's|what's) )\\b(?:kind|sort) of\\b(?! (?:a|an|the|thing|things|job|work|person|people|product|service|stuff|problem|issue)\\b)"), cut: true),
            Matcher(regex: re("\\ba bit(?= (?:late|early|slow|high|low|expensive|pricey|tight|longer|more|less|over|behind|busy|worried|concerned|unsure|confused)\\b)"), cut: true),
        ])

    static let unsourced = StyleTip(
        id: "unsourced", name: "Claims with no source", group: .clear, samples: ["studies show", "many experts say"], becomes: nil,
        message: "This asks the reader to trust a source they can\u{2019}t see. Name the source, or cut the phrase and own the claim.",
        matchers: [
            // Only with no owner in front: "our research shows" names its source.
            Matcher(regex: re("(?<!\\b(?:our|my|the|this|that|their|his|her|its|a|new|recent) )\\b(?:studies|research|science|surveys) (?:show|shows|suggest|suggests|prove|proves|has shown|have shown|says|say)(?: that)?\\b"), cut: true),
            Matcher(regex: re("\\b(?:many |most |some )?experts (?:say|agree|believe|recommend)(?: that)?\\b"), cut: true),
            Matcher(regex: re("\\b(?:it is|it's|it\u{2019}s) (?:widely|well|commonly) (?:known|accepted|believed)(?: that)?\\b"), cut: true),
            Matcher(regex: re("\\b(?:some|many|most) people (?:say|think|believe)(?: that)?\\b|\\beveryone knows(?: that)?\\b"), cut: true),
            Matcher(regex: re("\\barguably\\b"), cut: true),
            Matcher(regex: re("\\b(?:scientifically|clinically) proven\\b")),
            Matcher(regex: re("\\bup to \\d+(?:\\.\\d+)? ?(?:%|percent)")),
        ])

    static let twice = StyleTip(
        id: "twice", name: "Saying it twice", group: .clear, samples: ["free gift", "past history"], becomes: nil,
        message: "Both words say the same thing. One is enough.",
        matchers: list([("free gift", "gift"), ("free gifts", "gifts"), ("past history", "history"), ("each and every", "every"),
                        ("end result", "result"), ("end results", "results"), ("advance planning", "planning"),
                        ("plan ahead of time", "plan"), ("in close proximity to", "near"), ("close proximity", "proximity"),
                        ("future plans", "plans"), ("added bonus", "bonus"), ("basic fundamentals", "fundamentals"),
                        ("final outcome", "outcome"), ("unexpected surprise", "surprise"), ("joint collaboration", "collaboration"),
                        ("revert back", "revert"), ("reverted back", "reverted"), ("repeat again", "repeat"),
                        ("new innovation", "innovation"), ("true facts", "facts"), ("completely eliminate", "eliminate"),
                        ("advance warning", "warning"), ("ATM machine", "ATM"), ("PIN number", "PIN"),
                        ("general consensus", "consensus"), ("consensus of opinion", "consensus"), ("first began", "began"),
                        ("still remains", "remains"), ("brief summary", "summary"), ("sum total", "total"),
                        ("absolutely essential", "essential"), ("postpone until later", "postpone"),
                        ("return back", "return"), ("refer back", "refer"), ("combine together", "combine"),
                        ("merge together", "merge"), ("join together", "join"), ("over exaggerate", "exaggerate")])
            )

    static let plain = StyleTip(
        id: "plain", name: "Long-winded phrases", group: .clear, samples: ["in order to"], becomes: "to",
        message: "A shorter word says the same thing.",
        matchers: list([("utilize", "use"), ("utilise", "use"), ("in order to", "to"), ("at this point in time", "now"),
                        ("due to the fact that", "because"), ("in the event that", "if"), ("prior to", "before"),
                        ("commence", "start"), ("facilitate", "help"), ("a number of", "some")]))

    // MARK: Strong

    /// Found by LanguageTool's passive-voice rule (switched on only with this tip). See `LanguageTool.parse`.
    static let passive = StyleTip(
        id: "passive", name: "Hidden doer", group: .strong, samples: ["mistakes were made"], becomes: "we made mistakes",
        message: "This hides who did it. Name the doer first, as in \u{201C}we sent the invoice.\u{201D}",
        matchers: [])

    /// Verbs where a hidden doer usually hides who is responsible: the work, the money and the mistakes in
    /// customer writing. A passive like "the store was built in 1952" or "is called" is left alone.
    static let doerVerbs: Set<String> = ["made", "missed", "lost", "overlooked", "forgotten", "delayed", "damaged", "broken",
        "dropped", "cancelled", "canceled", "postponed", "rescheduled", "changed", "sent", "received", "done", "decided",
        "agreed", "approved", "rejected", "declined", "denied", "charged", "billed", "overcharged", "refunded", "ignored",
        "misplaced", "mislabeled", "mislabelled", "mishandled", "delivered", "shipped", "paid", "completed", "finished",
        "fixed", "repaired", "installed", "replaced", "booked", "scheduled", "processed", "reviewed", "checked", "inspected",
        "notified", "informed", "told", "quoted", "signed", "submitted", "issued", "ordered", "returned", "removed"]

    /// A passive is kept only when it hides the doer of a verb on the list: "was sent by our office" names it.
    public static func hidesDoer(_ r: NSRange, in ns: NSString) -> Bool {
        let verb = ns.substring(with: r).lowercased().split(separator: " ").last.map(String.init) ?? ""
        guard doerVerbs.contains(verb) else { return false }
        let rest = ns.substring(from: NSMaxRange(r))
        let sentence = rest.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? rest
        return sentence.range(of: "\\bby\\b", options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// The verb forms a noun phrase stands in for: (verbs in, noun, verbs out) in the order base, -s, past, -ing.
    static let nouns: [([String], String, [String])] = [
        (make, "(?:a |the )?decision", ["decide", "decides", "decided", "deciding"]),
        (make, "(?:a |the )?recommendation", ["recommend", "recommends", "recommended", "recommending"]),
        (make, "(?:an |the )?assumption", ["assume", "assumes", "assumed", "assuming"]),
        (make, "(?:a |the )?payment", ["pay", "pays", "paid", "paying"]),
        (make, "(?:a |the )?purchase", ["buy", "buys", "bought", "buying"]),
        (make, "(?:a |the )?suggestion", ["suggest", "suggests", "suggested", "suggesting"]),
        (["provide", "provides", "provided", "providing"], "assistance", ["help", "helps", "helped", "helping"]),
        (conduct, "(?:a |the )?review of", ["review", "reviews", "reviewed", "reviewing"]),
        (conduct, "(?:an |the )?investigation (?:of|into)", ["investigate", "investigates", "investigated", "investigating"]),
        (conduct + perform, "(?:an |the )?analysis of", ["analyze", "analyzes", "analyzed", "analyzing"]),
        (conduct, "(?:an |the )?inspection of", ["inspect", "inspects", "inspected", "inspecting"]),
        (["give", "gives", "gave", "giving"], "consideration to", ["consider", "considers", "considered", "considering"]),
        (["take", "takes", "took", "taking"], "into consideration", ["consider", "considers", "considered", "considering"]),
        (["reach", "reaches", "reached", "reaching"], "(?:a |the )?conclusion", ["conclude", "concludes", "concluded", "concluding"]),
        (["reach", "reaches", "reached", "reaching", "come to", "comes to", "came to", "coming to"], "(?:an |the )?agreement",
         ["agree", "agrees", "agreed", "agreeing"]),
        (["give", "gives", "gave", "giving"], "(?:your |their |final )?approval (?:to|for)", ["approve", "approves", "approved", "approving"]),
        (["have", "has", "had", "having"], "(?:a |the )?discussion (?:about|on)", ["discuss", "discusses", "discussed", "discussing"]),
    ]
    static let make = ["make", "makes", "made", "making"]
    static let conduct = ["conduct", "conducts", "conducted", "conducting"]
    static let perform = ["perform", "performs", "performed", "performing"]

    static let nominal = StyleTip(
        id: "nominal", name: "Verbs turned into nouns", group: .strong, samples: ["make a decision"], becomes: "decide",
        message: "A verb is hiding inside this noun. Use the verb and the sentence gets shorter.",
        matchers: nouns.map { verbs, noun, out in
            // "take into consideration" splits around its object; only the joined form is offered.
            Matcher(regex: re("\\b(" + verbs.map(words).joined(separator: "|") + ") " + noun + "\\b"), fix: { found in
                let lower = found.lowercased()
                let i = verbs.indices.filter { lower.hasPrefix(verbs[$0] + " ") }.max { verbs[$0].count < verbs[$1].count } ?? 0
                return out[i % 4]
            })
        })

    static let slowStart = StyleTip(
        id: "slowstart", name: "Slow starts", group: .strong, samples: ["I just wanted to reach out"], becomes: nil,
        message: "The reader is waiting for the point. Start with what you need.",
        matchers: [
            // A whole sentence of warm-up comes out whole.
            Matcher(regex: re(start + "(?:I hope (?:this|this email|this message|this note|this finds you|you are|you're|you\u{2019}re)(?: finds you)?(?: doing)? well|I hope you(?:'re|\u{2019}re| are) having a (?:good|great) (?:day|week))[.!] ?"),
                    fix: { _ in "" }),
            Matcher(regex: re(start + "(?:I wanted to let you know|I just wanted to let you know|I(?:'m|\u{2019}m| am) writing to let you know|this (?:email|message|note) is to let you know)(?: that)?\\b"),
                    cut: true),
            Matcher(regex: re(start + "(?:I (?:just )?wanted to (?:reach out|touch base|follow up|check in)|I(?:'m|\u{2019}m| am) (?:just )?(?:reaching out|writing)|just (?:wanted to )?(?:following up|checking in|reaching out))\\b")),
        ])

    static let apology = StyleTip(
        id: "apology", name: "Apologies", group: .strong, samples: ["Sorry to bother you, but"], becomes: nil,
        message: "Opening with sorry makes a fair request sound like a favour. Thank them, or get to the point.",
        matchers: [
            Matcher(regex: re(start + "(?:I(?:'m|\u{2019}m| am) )?(?:so |very |really )?sorry (?:for the (?:delay|late reply|slow reply|wait)|for my (?:late|slow) reply)[.!]"),
                    fix: { _ in "Thanks for waiting." }),
            Matcher(regex: re(start + "(?:my )?apologies for (?:the|any) (?:delay|late reply|wait)[.!]"), fix: { _ in "Thanks for waiting." }),
            Matcher(regex: re(start + "(?:(?:my )?apologies|I apologi[sz]e|(?:I(?:'m|\u{2019}m| am) )?(?:so |very )?sorry) for (?:the|any) inconvenience[.!]"),
                    fix: { _ in "Thanks for your patience." }),
            Matcher(regex: re(start + "(?:I(?:'m|\u{2019}m| am) )?(?:so )?sorry (?:to bother you|to trouble you|for bothering you|to be a pain|if this is a (?:silly|dumb) question)(?:,? but)?")),
        ])

    // MARK: Fresh

    static let cliche = StyleTip(
        id: "cliche", name: "Clich\u{E9}s and jargon", group: .fresh, samples: ["circle back", "low-hanging fruit"], becomes: nil,
        message: "Readers skim past phrases they have heard a hundred times. Say the plain thing.",
        matchers: [Matcher(regex: re("\\b(?:circl(?:e|es|ed|ing) back|loop(?:s|ed|ing)? back|low[- ]hanging fruit|touch(?:es|ed|ing)? base|mov(?:e|es|ed|ing) the needle|at the end of the day|(?:think|thinking) outside the box|game[- ]changer|game[- ]changing|deep dive|take (?:this|it) offline|win[- ]win|paradigm shift|hit the ground running|on the same page|ballpark (?:figure|number)|per my last email|level[- ]set|boil the ocean|drill down|run it up the flagpole|the elephant in the room|it is what it is|value[- ]add|no[- ]brainer|at this juncture|in a nutshell|hit the nail on the head|tip of the iceberg|back to the drawing board|bring to the table|brings to the table|best of breed|ducks in a row|pick your brain|pick his brain|pick her brain)\\b"))])

    static let soundsLikeAI = StyleTip(
        id: "ai", name: "Sounds like AI", group: .fresh, samples: ["delve", "seamless", "tapestry"], becomes: nil,
        message: "Readers link this with machine writing. Say the concrete thing.",
        matchers: list([("delve", nil), ("delves", nil), ("tapestry", nil), ("landscape", nil), ("leverage", nil),
                        ("seamless", nil), ("seamlessly", nil), ("robust", nil), ("holistic", nil), ("synergy", nil),
                        ("paradigm", nil), ("ecosystem", nil), ("it's worth noting", nil), ("in today's fast-paced world", nil)])
            // "Not only X but also Y" (The Economist, Jul 30 2026): only when "but" follows in the same sentence.
            + [Matcher(regex: re("\\bnot only\\b(?=[^.!?\\n]*\\bbut\\b)"))])

    static let promises = StyleTip(
        id: "promises", name: "Promises you can\u{2019}t keep", group: .fresh, samples: ["guaranteed", "never fails"], becomes: nil,
        message: "A promise like this is easy to doubt and hard to keep. Say what you will actually do.",
        matchers: [Matcher(regex: re("\\b(?:(?:satisfaction|results?|quality|savings|delivery|lowest prices?|money[- ]back) guaranteed|guaranteed (?:results|savings|satisfaction|delivery|lowest|best|to (?:work|last|save|fix|love))|we guarantee|100 ?% (?:satisfaction|satisfied|guaranteed|risk[- ]free)|never (?:fails|fail)|always on time|never late|best[- ]in[- ]class|world[- ]class|unbeatable|risk[- ]free|zero risk|perfect results|lowest prices? (?:anywhere|in town))\\b|" + start + "guaranteed\\b|\\b(?:we are|we're|we\u{2019}re|is|are) the (?:best|cheapest|fastest|number one|#1)(?= *(?:[.!,]|$| in (?:town|the city|the business|the industry|the area|the country)\\b))"))])
}

extension HouseStyle {
    /// The style tips switched on. Stored under the 0.8 name `starterSets` so older settings files keep theirs.
    public var tips: [String] {
        get { starterSets }
        set { starterSets = newValue }
    }
}
