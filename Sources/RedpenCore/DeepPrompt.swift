import Foundation

/// What Deep check asks Claude to do with the text.
public enum DeepMode: String, CaseIterable, Sendable {
    /// Fix grammar and spelling, keep everything else.
    case fixOnly
    /// Rewrite as an email that follows `EmailRules`.
    case email
}

/// Ten rules for an email that asks someone for something. Written in Redpen's own words. The ideas come from
/// Joanna Wiebe's Copyhackers courses and from Todd Rogers and Jessica Lasky-Fink, "Writing for Busy Readers" (2023).
public enum EmailRules {
    public static let rules: [String] = [
        "Put the ask in the first two lines, not under the background.",
        "One email, one ask. If there are several, keep the urgent one or number them.",
        "Cut what the reader does not need: background before the point, the same thing said twice, a sign-off that repeats the ask.",
        "The subject line says what the email is for. \"Quick question\" and \"Following up\" say nothing.",
        "Start with the reader, not the sender. Drop openers like \"I hope this finds you well\" or \"I wanted to reach out\".",
        "Say why it matters to the reader, or why it is their call.",
        "Make saying yes easy: offer two times instead of asking when they are free, include the link or file, say when you need an answer and why.",
        "Name the actual thing instead of a summary like \"the deliverables\" or \"next steps\".",
        "Short sentences and common words. One thought per sentence.",
        "Answer the obvious worry before they ask: how long it takes, what it costs, what happens next.",
    ]

    static var numbered: String { rules.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
}

public enum DeepPrompt {
    /// The instructions for the Deep check model, from the writer's house style and the chosen mode.
    public static func build(_ style: HouseStyle, mode: DeepMode) -> String {
        var rules: [String] = []
        if style.noDashes { rules.append("no em dashes; use a period or comma") }
        if style.colonsOnlyForLabels { rules.append("colons only for labels and lists; a colon joining two thoughts becomes a period") }
        if !style.containerWords.isEmpty { rules.append("avoid vague words like " + style.containerWords.prefix(6).joined(separator: ", ")) }
        if !style.disclaimers.isEmpty { rules.append("cut defensive disclaimers") }
        if style.flagOtherLanguages { rules.append("the result must be in English") }
        for tip in StyleTip.all where style.tips.contains(tip.id) {
            switch tip.id {
            case "plain": rules.append("prefer the short plain word (use, not utilize; to, not in order to)")
            case "ai": rules.append("avoid words readers link with machine writing, such as delve, tapestry, seamless, and the not only... but also build-up")
            case "softeners": rules.append("cut softeners such as I think, sort of, maybe")
            case "filler": rules.append("cut filler words such as basically, actually, you know")
            case "unsourced": rules.append("no claims with an unnamed source, such as studies show or experts say")
            case "twice": rules.append("cut words that repeat each other, such as free gift or past history")
            case "passive": rules.append("name who did it rather than hiding the doer in the passive voice")
            case "nominal": rules.append("use the verb, not a noun made from it (decide, not make a decision)")
            case "slowstart": rules.append("start with the point, not a warm-up such as I just wanted to reach out")
            case "apology": rules.append("no apologies for asking, such as sorry to bother you")
            case "cliche": rules.append("no business cliches such as circle back or low-hanging fruit")
            case "promises": rules.append("no promises that cannot be kept, such as guaranteed or never fails")
            default: break
            }
        }

        var p: String
        switch mode {
        case .fixOnly:
            p = "Edit the text on stdin. Fix grammar and spelling. Keep the writer's meaning and voice; do not add ideas."
        case .email:
            p = "Rewrite the text on stdin as an email that follows the email rules below. Keep the writer's meaning and voice. "
              + "Never invent facts, dates, times, names, prices or links. Where a rule needs something only the writer knows, "
              + "leave a short bracketed gap such as [deadline] and say so in NOTES. If the text has no subject line, do not add one."
        }
        if !rules.isEmpty { p += " Also apply the writer's house style: " + rules.joined(separator: "; ") + "." }
        let notes = style.deepCheckNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { p += " Writer's notes: " + notes }
        p += "\n\nEmail rules:\n" + EmailRules.numbered + "\n\n"
        switch mode {
        case .fixOnly:
            p += "Do not apply the email rules to REVISED: keep its order, length and wording apart from grammar and spelling. "
               + "If the text is an email or message asking someone for something, add NOTES: at most three, the ones that matter most, "
               + "each a plain sentence naming what to change. Weigh rules 1, 2 and 7 first. Leave NOTES out when none apply."
        case .email:
            p += "NOTES lists only what the writer must still fill in or decide, at most three. Leave NOTES out when there is nothing."
        }
        return p + "\n" + format
    }

    public static let format = """
    Reply in exactly this form, plain text, no markdown headings:
    REVISED
    <the full revised text>

    CHANGES
    - <one short line per change, most important first>

    NOTES
    - <one plain sentence per note>
    """
}
