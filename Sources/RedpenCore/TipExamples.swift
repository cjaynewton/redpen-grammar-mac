import Foundation

/// Before-and-after examples for every style tip, written for small-business writing: quotes, invoices and
/// customer emails. Shown under the "i" on the Style tips page and under "More examples" in the fix box.
/// Written by hand and shipped inside the app, so they work with no internet.
public struct TipExamples: Sendable {
    /// One pair. In `before`, the words the tip marks sit in [square brackets]; in `after`, new words sit in {braces}.
    public struct Pair: Sendable {
        public let before: String
        public let after: String
        /// (text, marked) runs, for drawing the struck or highlighted words.
        public var beforeRuns: [(String, Bool)] { TipExamples.runs(before, open: "[", close: "]") }
        public var afterRuns: [(String, Bool)] { TipExamples.runs(after, open: "{", close: "}") }
    }

    /// One plain sentence on why the tip matters.
    public let why: String
    public let pairs: [Pair]
    /// When the tip is wrong and the words should stay.
    public let leaveWhen: String

    public static func of(_ tip: String) -> TipExamples? { all[tip] }

    /// Splits "We [just] wanted" into runs, with curly apostrophes and quotes for display.
    static func runs(_ s: String, open: Character, close: Character) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var cur = "", inside = false
        for c in s {
            if c == open || c == close {
                if !cur.isEmpty { out.append((curly(cur), inside)) }
                cur = ""; inside = c == open
            } else { cur.append(c) }
        }
        if !cur.isEmpty { out.append((curly(cur), inside)) }
        return out
    }

    /// Straight quotes as typeset ones: an apostrophe or closing quote after a letter, an opening one elsewhere.
    public static func curly(_ s: String) -> String {
        var out = ""
        var prev: Character = " "
        for c in s {
            switch c {
            case "'": out.append(prev.isLetter || prev.isNumber || prev == "." ? "\u{2019}" : "\u{2018}")
            case "\"": out.append(prev == " " || prev == "(" ? "\u{201C}" : "\u{201D}")
            default: out.append(c)
            }
            prev = c
        }
        return out
    }

    static func p(_ before: String, _ after: String) -> Pair { Pair(before: before, after: after) }

    static let all: [String: TipExamples] = [
        "filler": TipExamples(
            why: "Filler words take up room and make you sound less sure.",
            pairs: [p("We [just] wanted to check in on the deposit.", "We wanted to check in on the deposit."),
                    p("The install is [basically] done.", "The install is {done except the trim}."),
                    p("[Um, so] the crew arrives at eight.", "The crew arrives at eight."),
                    p("We can start Monday, [you know,] if the permit comes in.", "We can start Monday if the permit comes in.")],
            leaveWhen: "Leave it when the word carries meaning. \"I just finished\" means a moment ago."),
        "softeners": TipExamples(
            why: "A softener makes a firm price or date sound like a guess.",
            pairs: [p("[I think] the repair will cost about $400.", "The repair will cost about $400."),
                    p("We could [maybe] start on Monday.", "We {can} start on Monday."),
                    p("The paint is [kind of] faded on the north wall.", "The paint is faded on the north wall."),
                    p("[It seems] the invoice was paid twice.", "{Our records show} the invoice was paid twice.")],
            leaveWhen: "Leave it when you really are unsure. \"I think it's the pump, but I'll know when I open it\" is honest."),
        "unsourced": TipExamples(
            why: "A claim with nobody behind it asks the reader to trust a source they can't see.",
            pairs: [p("[Studies show] customers prefer same-day quotes.", "In our shop, {8 in 10} customers chose the same-day quote."),
                    p("[Many experts say] spring is the best time to repaint.", "Spring is the best time to repaint{, because the paint dries before the summer rain}."),
                    p("[It is widely known that] late invoices get paid last.", "Late invoices get paid last."),
                    p("This will save you [up to 50%].", "This saved our last client {32%} in the first year.")],
            leaveWhen: "Leave it when you name the source. \"A 2025 Statistics Canada survey shows\" is fine."),
        "twice": TipExamples(
            why: "When two words say the same thing, the second one wastes the reader's time.",
            pairs: [p("Every order comes with a [free] gift.", "Every order comes with a gift."),
                    p("We checked the [past] history of the account.", "We checked the history of the account."),
                    p("[Each and] every invoice is due in 30 days.", "Every invoice is due in 30 days."),
                    p("The [end] result is a dry basement.", "The result is a dry basement.")],
            leaveWhen: "Leave it when the extra word tells the reader something new. \"Past due\" is not the same as \"due.\""),
        "plain": TipExamples(
            why: "Short words are faster to read and harder to misread.",
            pairs: [p("[In order to] book, send the deposit.", "{To} book, send the deposit."),
                    p("We will [commence] work on May 3.", "We will {start} work on May 3."),
                    p("[Due to the fact that] the part is late, we moved the date.", "{Because} the part is late, we moved the date."),
                    p("Please pay [prior to] pickup.", "Please pay {before} pickup.")],
            leaveWhen: "Leave it when the long word is the right term, like \"commence\" in a signed contract."),
        "passive": TipExamples(
            why: "When the doer is hidden, the reader can't tell who is responsible.",
            pairs: [p("Mistakes [were made] on your invoice.", "{We made} mistakes on your invoice."),
                    p("The invoice [was sent] on Monday.", "{We sent} the invoice on Monday."),
                    p("Your deposit [has been received].", "{We received} your deposit."),
                    p("The furnace [was inspected] last week.", "{Sam inspected} the furnace last week.")],
            leaveWhen: "Leave it when the doer doesn't matter, like \"The store was built in 1952.\""),
        "nominal": TipExamples(
            why: "A verb turned into a noun takes more words to say less.",
            pairs: [p("We need to [make a decision] by Friday.", "We need to {decide} by Friday."),
                    p("Our team will [conduct a review of] your account.", "Our team will {review} your account."),
                    p("We are happy to [provide assistance] with setup.", "We are happy to {help} with setup."),
                    p("Please [give consideration to] the second quote.", "Please {consider} the second quote.")],
            leaveWhen: "Leave it when the noun is the thing itself, like \"The decision is yours.\""),
        "slowstart": TipExamples(
            why: "The first line is the one people read, so put your point there.",
            pairs: [p("[I just wanted to reach out] to ask about the deposit.", "{Could you send} the deposit by Friday?"),
                    p("[I hope this email finds you well.] Your order shipped today.", "Your order shipped today."),
                    p("[I wanted to let you know that] the price goes up in June.", "The price goes up {on June 1}."),
                    p("[I wanted to follow up] on my last email.", "{Did you get a chance to look at} the quote I sent Tuesday?")],
            leaveWhen: "Leave it when you write to someone for the first time and a short hello helps."),
        "apology": TipExamples(
            why: "Starting with sorry makes a fair request sound like a favour.",
            pairs: [p("[Sorry to bother you, but] the invoice is past due.", "The invoice {was due on May 1}."),
                    p("[Sorry for the delay.] Here is your quote.", "{Thanks for waiting.} Here is your quote."),
                    p("[Apologies for the inconvenience.] The crew comes Thursday.", "{Thanks for your patience.} The crew comes Thursday.")],
            leaveWhen: "Leave it when you made a real mistake. Then say sorry once and say what you will do."),
        "cliche": TipExamples(
            why: "Readers skim past phrases they have heard a hundred times.",
            pairs: [p("Let's [circle back] next week.", "Let's {talk again on Tuesday}."),
                    p("Fixing the gutters is [low-hanging fruit].", "Fixing the gutters is {quick and cheap}."),
                    p("I'd like to [touch base] about the order.", "I {have a question} about the order."),
                    p("[At the end of the day,] the cheaper pump costs more.", "{Over five years,} the cheaper pump costs more.")],
            leaveWhen: "Leave it when everyone you write to uses the phrase and it saves them time."),
        "ai": TipExamples(
            why: "Readers now link these words with text a machine wrote, and they trust it less.",
            pairs: [p("We [seamlessly] handle your booking.", "We {book you in one call}."),
                    p("Let's [delve] into your options.", "Let's {look at} your options."),
                    p("Our [robust] process keeps you informed.", "{We text you after every visit.}"),
                    p("We [leverage] local suppliers.", "We {buy from} local suppliers.")],
            leaveWhen: "Leave it when the word is the plain one for your trade, like \"landscape\" for a landscaper."),
        "promises": TipExamples(
            why: "A promise you can't keep is easy to doubt and hard to defend.",
            pairs: [p("Results [guaranteed].", "{If the stain comes back in 30 days, we clean it again for free.}"),
                    p("We [are the best] in town.", "We {have 212 five-star reviews}."),
                    p("Our pumps [never fail].", "Our pumps {come with a five-year warranty}."),
                    p("[100% satisfaction] on every job.", "{If you're not happy, we come back and fix it.}")],
            leaveWhen: "Leave it when you put the promise in writing with clear terms, like a written warranty."),
    ]
}
