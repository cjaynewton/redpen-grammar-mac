import Foundation
import AppKit
import RedpenCore

// 30 planted errors plus 5 clean sentences. `expect` is the text a correct checker must flag (nil = clean).
struct Case { let text: String; let expect: String?; let group: String }

let cases: [Case] = [
    // Spelling
    Case(text: "I recieved the samples on Tuesday.", expect: "recieved", group: "spelling"),
    Case(text: "The buyer was definately interested in the endcap.", expect: "definately", group: "spelling"),
    Case(text: "We need a seperate line for the club channel.", expect: "seperate", group: "spelling"),
    Case(text: "Her occurence report came in late.", expect: "occurence", group: "spelling"),
    Case(text: "Send the invoce to Maria before noon.", expect: "invoce", group: "spelling"),
    Case(text: "The margins are untill the end of the quarter.", expect: "untill", group: "spelling"),
    Case(text: "That was a truely bad quarter for the brand.", expect: "truely", group: "spelling"),
    Case(text: "We should acommodate the retailer's timeline.", expect: "acommodate", group: "spelling"),
    Case(text: "The pallet arived damaged at the warehouse.", expect: "arived", group: "spelling"),
    Case(text: "Its a beleif most founders hold about retail.", expect: "beleif", group: "spelling"),
    // Grammar
    Case(text: "The buyers was happy with the new packaging.", expect: "was", group: "grammar"),
    Case(text: "Their going to send the purchase order tomorrow.", expect: "Their", group: "grammar"),
    Case(text: "The brand lost it's shelf space last spring.", expect: "it's", group: "grammar"),
    Case(text: "Me and Sam met the buyer in Toronto.", expect: "Me and Sam", group: "grammar"),
    Case(text: "She don't think the price increase will hold.", expect: "don't", group: "grammar"),
    Case(text: "The new pricing will effect every SKU in the line.", expect: "effect", group: "grammar"),
    Case(text: "We could of closed the deal last week.", expect: "could of", group: "grammar"),
    Case(text: "Each of the retailers have their own deduction policy.", expect: "have", group: "grammar"),
    Case(text: "Yesterday we go to the trade show and meet three buyers.", expect: "go", group: "grammar"),
    Case(text: "The report was wrote by the category manager.", expect: "wrote", group: "grammar"),
    // House-style rules (the example style, all on)
    Case(text: "The buyer walked past the display\u{2014}twice.", expect: "\u{2014}", group: "rules"),
    Case(text: "The margin looked healthy \u{2013} until the deductions arrived.", expect: "\u{2013}", group: "rules"),
    Case(text: "The founder learned something the hard way: retail pays you last and charges you first.", expect: ":", group: "rules"),
    Case(text: "There is one reason the brand stalled in year two: the trade spend ate the margin whole.", expect: ":", group: "rules"),
    Case(text: "Nobody is lying here, but the numbers do not add up.", expect: "Nobody is lying here", group: "rules"),
    Case(text: "Necesito enviar el contrato al comprador mañana por la mañana.", expect: "Necesito", group: "rules"),
    Case(text: "Le prix est trop élevé pour ce détaillant cette année.", expect: "prix", group: "rules"),
    Case(text: "The retail landscape has shifted for small brands.", expect: "landscape", group: "rules"),
    Case(text: "We can leverage the Costco relationship next year.", expect: "leverage", group: "rules"),
    Case(text: "The pricing framework failed at the second retailer.", expect: "framework", group: "rules"),
    // Clean
    Case(text: "The buyer walked past the display twice.", expect: nil, group: "clean"),
    Case(text: "Capital deployed: $400K", expect: nil, group: "clean"),
    Case(text: "We shipped three pallets to the Guelph store on Friday.", expect: nil, group: "clean"),
    Case(text: "Maria and I reviewed the deck before the call.", expect: nil, group: "clean"),
    Case(text: "Bring the samples, the price sheet, and the planogram.", expect: nil, group: "clean"),
]


// Held-out set: written after tuning, never used to adjust the engine.
let heldOut: [Case] = [
    Case(text: "The distributer called about the late shipment.", expect: "distributer", group: "spelling"),
    Case(text: "We recomend a smaller first order.", expect: "recomend", group: "spelling"),
    Case(text: "The comittee approved the new planogram.", expect: "comittee", group: "spelling"),
    Case(text: "Their was a problem with the pallet labels.", expect: "Their", group: "grammar"),
    Case(text: "Who's samples are these on the table?", expect: "Who's", group: "grammar"),
    Case(text: "The data shows that sales has dropped since March.", expect: "has", group: "grammar"),
    Case(text: "Him and Maria are driving to Guelph.", expect: "Him and Maria", group: "grammar"),
    Case(text: "I seen the new display at the store last week.", expect: "seen", group: "grammar"),
    Case(text: "The buyer should of told us sooner.", expect: "should of", group: "grammar"),
    Case(text: "Less brands made it through the line review this year.", expect: "Less", group: "grammar"),
    Case(text: "The deal fell apart for one reason: nobody owned the follow-up with the buyer.", expect: ":", group: "rules"),
    Case(text: "We moved fast\u{2014}maybe too fast.", expect: "\u{2014}", group: "rules"),
    Case(text: "Vamos a revisar los precios con el distribuidor la próxima semana.", expect: "Vamos", group: "rules"),
    Case(text: "This is not a conspiracy, it is just how the terms work.", expect: "This is not a conspiracy", group: "rules"),
    Case(text: "The brand's trajectory changed after the Costco test.", expect: "trajectory", group: "rules"),
    Case(text: "The store manager moved our product to the bottom shelf.", expect: nil, group: "clean"),
    Case(text: "Payment terms: net 60", expect: nil, group: "clean"),
    Case(text: "We sold 400 units in the first two weeks, then sales stalled.", expect: nil, group: "clean"),
    Case(text: "If the buyer says yes, we ship on the 14th.", expect: nil, group: "clean"),
    Case(text: "Sam and I will review the quote tonight.", expect: nil, group: "clean"),
]

@MainActor
func run() async {
    var cases = CommandLine.arguments.contains("--held-out") ? heldOut : cases
    if let i = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--blind") }) {
        let a = CommandLine.arguments
        let file = a[i] == "--blind2" ? "Tests/blind2.tsv" : a[i] == "--blind3" ? "Tests/blind3.tsv" : a[i] == "--blind-file" ? a[i + 1] : "Tests/blind.tsv"
        let tsv = try! String(contentsOfFile: file, encoding: .utf8)
        cases = tsv.split(separator: "\n").map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return Case(text: f[1], expect: f.count > 2 && !f[2].isEmpty ? f[2] : nil, group: f[0])
        }
    }
    let cleanTotal = cases.filter { $0.expect == nil }.count
    print("Apple model available:", AppleModel.isAvailable)
    var caught: [String: (Int, Int)] = [:]
    var falsePos = 0
    var taught = 0, caughtTotal = 0
    var noLesson: [String] = []
    var ruleFlags = 0  // clean text flagged only by house-style rules (colons, container words): not an error
    var totalTime = 0.0
    for c in cases {
        let t = Date()
        let issues = await Engine.full(c.text, longform: true, style: .example)
        totalTime += Date().timeIntervalSince(t)
        let ns = c.text as NSString
        var hit = false
        if let e = c.expect {
            let er = ns.range(of: e)
            hit = issues.contains { NSIntersectionRange($0.range, er).length > 0 }
            var g = caught[c.group] ?? (0, 0); g.1 += 1; if hit { g.0 += 1 }; caught[c.group] = g
            if hit {
                caughtTotal += 1
                if issues.contains(where: { NSIntersectionRange($0.range, er).length > 0 && Lessons.lesson(for: $0) != nil }) { taught += 1 }
                else { noLesson.append(c.text) }
            }
        } else if issues.contains(where: { $0.kind != .voice }) { falsePos += 1 } else if !issues.isEmpty { ruleFlags += 1 }
        let errorFlags = issues.contains { $0.kind != .voice }
        let mark = c.expect == nil ? (errorFlags ? "FALSE+" : issues.isEmpty ? "CLEAN" : "RULE") : (hit ? "CAUGHT" : "MISSED")
        print("\(mark.padding(toLength: 7, withPad: " ", startingAt: 0)) \(c.text)")
        for i in issues {
            print("         [\(i.tentative ? "maybe" : i.kind.rawValue)] \"\(i.original)\" -> \(i.replacements.first.map { "\"\($0)\"" } ?? "(flag)")  \(i.message)")
            if let l = Lessons.lesson(for: i) { print("           lesson \(l.id): \(l.rule)") }
        }
    }
    print("\nScore")
    let groups = ["spelling", "grammar", "rules"] + caught.keys.filter { !["spelling", "grammar", "rules"].contains($0) }.sorted()
    for g in groups { let v = caught[g] ?? (0, 0); print("  \(g): \(v.0)/\(v.1)") }
    print("  clean sentences wrongly flagged: \(falsePos)/\(cleanTotal)")
    print("  clean sentences flagged by house-style rules only: \(ruleFlags)/\(cleanTotal)")
    print("  caught mistakes that come with a lesson: \(taught)/\(caughtTotal)")
    for t in noLesson { print("    no lesson: \(t)") }
    print(String(format: "  average time per sentence: %.2fs", totalTime / Double(cases.count)))
}

/// Self-check for the patterns page: fake fixes in a temp file, then print the weekly report.
func patternsDemo() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-patterns-\(UUID().uuidString).jsonl")
    let m = Mistakes(url: url)
    let now = Date()
    let its = Issue(range: NSRange(location: 0, length: 4), kind: .grammar, message: "Possible typo", replacements: ["it's"], original: "its")
    let your = Issue(range: NSRange(location: 0, length: 4), kind: .grammar, message: "Possible typo", replacements: ["You're"], original: "Your")
    let spell = Issue(range: NSRange(location: 0, length: 9), kind: .spelling, message: "", replacements: ["definitely"], original: "definitly")
    for d in [1.0, 2, 3] { m.record(its, replacement: "it's", app: "test", at: now.addingTimeInterval(-d * 86_400)) }
    for d in [8.0, 9, 10, 11] { m.record(its, replacement: "it's", app: "test", at: now.addingTimeInterval(-d * 86_400)) }
    m.record(spell, replacement: "definitely", app: "test", at: now.addingTimeInterval(-86_400))
    m.record(your, replacement: "You're", app: "test", at: now.addingTimeInterval(-9 * 86_400))
    print(m.report(now: now))
    print("its/it's in last 30 days:", m.count("its-its", now: now))
    try? FileManager.default.removeItem(at: url)
}

/// The fix card's placement and click rules (`--card`). Rects are Cocoa screen coordinates.
func cardChecks() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { failed += 1 } }
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let size = CGSize(width: 340, height: 180)
    let word = CGRect(x: 400, y: 600, width: 40, height: 20)
    let below = CardPlacement.origin(anchor: word, size: size, visible: screen, avoid: [])
    check("opens below the word", below.y + size.height <= word.minY)
    check("lines up with the word", below.x == word.minX - 16)
    let nearBottom = CGRect(x: 400, y: 60, width: 40, height: 20)
    check("opens above when there is no room below",
          CardPlacement.origin(anchor: nearBottom, size: size, visible: screen, avoid: []).y >= nearBottom.maxY)
    let nextLine = CGRect(x: 420, y: 560, width: 50, height: 20)  // another mistake one line down
    let p = CardPlacement.origin(anchor: word, size: size, visible: screen, avoid: [word, nextLine])
    check("opens above rather than cover a mistake below", p.y >= word.maxY)
    check("never covers its own word", !CGRect(origin: p, size: size).intersects(word))
    let both = CardPlacement.origin(anchor: word, size: size, visible: screen, avoid: [nextLine, CGRect(x: 420, y: 640, width: 50, height: 20)])
    check("stays below when both sides cover a mistake", both.y + size.height <= word.minY)
    let rightEdge = CGRect(x: 1580, y: 600, width: 15, height: 20)
    check("stays on screen at the right edge",
          CardPlacement.origin(anchor: rightEdge, size: size, visible: screen, avoid: []).x + size.width <= screen.maxX)

    check("click on an underline opens the card", CardPlacement.onClick(cardOpen: false, hit: true, hitSame: false) == .open)
    check("click elsewhere does nothing", CardPlacement.onClick(cardOpen: false, hit: false, hitSame: false) == .ignore)
    check("double-click keeps the card", CardPlacement.onClick(cardOpen: true, hit: true, hitSame: true) == .keep)
    check("click on another underline switches the card", CardPlacement.onClick(cardOpen: true, hit: true, hitSame: false) == .open)
    check("click away closes the card", CardPlacement.onClick(cardOpen: true, hit: false, hitSame: false) == .close)
    // Your patterns summary for the menu panel.
    let now = Date()
    func rec(_ daysAgo: Double, _ lesson: String, _ o: String, _ r: String) -> MistakeRecord {
        MistakeRecord(date: now.addingTimeInterval(-daysAgo * 86_400), lesson: lesson, title: "t", original: o, replacement: r, app: "x")
    }
    let recs = [rec(1, "spell-receive", "recieve", "receive"), rec(2, "spell-receive", "recieve", "receive"),
                rec(9, "spell-receive", "recieve", "receive"), rec(16, "spell-receive", "recieve", "receive"),
                rec(17, "spell-receive", "recieve", "receive"), rec(23, "spell-receive", "recieve", "receive"),
                rec(24, "spell-receive", "recieve", "receive"), rec(25, "spell-receive", "recieve", "receive"),
                rec(3, "its-its", "its", "it's"), rec(100, "old", "a", "b")]
    let sum = PatternSummary(recs, now: now)
    check("fixes this week counted", sum.thisWeek == 3)
    check("fixes the week before counted", sum.lastWeek == 1)
    check("mistakes older than eight weeks left out", !sum.rows.contains { $0.lesson == "old" })
    check("most frequent this week comes first", sum.rows.first?.lesson == "spell-receive")
    check("eight weekly bars, this week last", sum.rows.first?.weeks == [0, 0, 0, 0, 3, 2, 1, 2])
    check("spelling rows marked as spelling", sum.rows.first?.spelling == true && sum.rows.last?.spelling == false)
    check("a first-time mistake reads as new", sum.rows.last?.trend == "new this week")
    check("trend compares with the usual week", sum.rows.first?.trend == "about the same as usual")
    check("no records gives an empty summary", PatternSummary([]).rows.isEmpty)

    print(failed == 0 ? "card checks: all pass" : "card checks: \(failed) failed")
    if failed > 0 { exit(1) }
}

/// The email rules reach Claude's instructions in both Deep check modes (`--email`).
func emailChecks() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { failed += 1 } }
    let fix = DeepPrompt.build(HouseStyle(), mode: .fixOnly)
    let email = DeepPrompt.build(HouseStyle.example, mode: .email)
    check("ten email rules", EmailRules.rules.count == 10)
    check("every rule in the email prompt", EmailRules.rules.allSatisfy { email.contains($0) })
    check("fix only still fixes only", fix.contains("Fix grammar and spelling") && !fix.contains("Rewrite the text"))
    check("fix only keeps email rules out of the edit", fix.contains("Do not apply the email rules to REVISED"))
    check("fix only gives at most three notes", fix.contains("at most three"))
    check("email never invents facts", email.contains("Never invent"))
    check("house style carried into the email rewrite", email.contains("no em dashes"))
    check("reply format has NOTES", DeepPrompt.format.contains("NOTES"))
    check("rules have no em dashes", !EmailRules.rules.joined().contains("\u{2014}"))
    print(failed == 0 ? "email checks: all pass" : "email checks: \(failed) failed")
    if failed > 0 { exit(1) }
}

/// Inputs that used to crash or mislead Redpen (`--safety`), from the Oct 16 2026 Codex review.
@MainActor
func safetyChecks() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { failed += 1 } }

    var style = HouseStyle()
    style.disclaimers = ["to be clear,"]
    let dotted = "\u{130} to be clear, the price holds."
    let found = Rules.check(dotted, longform: false, style: style).filter { $0.message.hasPrefix("Disclaimer") }
    check("dotted capital I before a disclaimer: no crash, right words", found.count == 1 && found[0].original == "to be clear,")
    let mixed = Rules.check("To Be Clear, we ship.", longform: false, style: style).filter { $0.message.hasPrefix("Disclaimer") }
    check("disclaimer found in any case", mixed.first?.original == "To Be Clear,")

    // Starter sets (Oct 17 2026): whole words only, either apostrophe, capitals kept, own list wins.
    var sets = HouseStyle()
    sets.starterSets = ["plain", "ai"]
    let plain = Rules.check("Utilize the tools in order to win.", longform: false, style: sets).filter { $0.kind == .voice }
    check("plain English offers the short word with its capital", plain.contains { $0.original == "Utilize" && $0.replacements == ["Use"] })
    check("plain English catches a phrase", plain.contains { $0.original == "in order to" && $0.replacements == ["to"] })
    check("starter set ignores part of a word", Rules.check("The redelve team.", longform: false, style: sets).allSatisfy { $0.kind != .voice })
    check("curly apostrophe matches", Rules.check("It\u{2019}s worth noting the cost.", longform: false, style: sets).contains { $0.kind == .voice })
    check("switched-off set stays quiet", Rules.check("I think so.", longform: false, style: sets).allSatisfy { $0.kind != .voice })
    check("all capitals stay all capitals", Rules.check("UTILIZE IT.", longform: false, style: sets).contains { $0.replacements == ["USE"] })
    sets.containerWords = ["in order to"]
    check("a phrase on your own list still gets the starter warning",
          Rules.check("We trained in order to win.", longform: true, style: sets).contains { $0.original == "in order to" })
    sets.containerWords = ["leverage"]
    check("a word on your own list is flagged once", Rules.check("We leverage it.", longform: true, style: sets).filter { $0.original == "leverage" }.count == 1)

    let stale = Issue(range: NSRange(location: 40, length: 6), kind: .grammar, message: "x", replacements: ["y"], original: "Paris.")
    check("grammar result from longer old text is dropped, no crash", Engine.protectNames([stale], in: "a").isEmpty)
    let moved = Issue(range: NSRange(location: 0, length: 3), kind: .grammar, message: "x", replacements: ["y"], original: "dog")
    check("grammar result whose words changed is dropped", Engine.protectNames([moved], in: "cat sat").isEmpty)

    func reply(_ offset: Int, _ length: Int) -> Data {
        Data(#"{"matches":[{"message":"m","offset":\#(offset),"length":\#(length),"replacements":[{"value":"v"}],"rule":{"id":"R"}}]}"#.utf8)
    }
    check("negative offset from the engine is ignored", LanguageTool.parse(reply(-1, 1), text: "hello") == [])
    check("huge offset from the engine is ignored", LanguageTool.parse(reply(Int.max, 1), text: "hello") == [])
    check("range past the end is ignored", LanguageTool.parse(reply(3, 5), text: "hello") == [])
    check("a good range still comes through", LanguageTool.parse(reply(0, 5), text: "hello")?.first?.original == "hello")
    check("an answer that isn't LanguageTool's is no answer", LanguageTool.parse(Data("<html>".utf8), text: "hello") == nil)

    check("port 8081 answering with a web page is not LanguageTool", !LanguageTool.looksLikeLanguageTool(Data("<html>ok</html>".utf8)))
    check("port 8081 answering with an empty list is not LanguageTool", !LanguageTool.looksLikeLanguageTool(Data("[]".utf8)))
    check("LanguageTool's own language list is accepted",
          LanguageTool.looksLikeLanguageTool(Data(#"[{"name":"English (Canada)","code":"en","longCode":"en-CA"}]"#.utf8)))

    // Calm mode and Fix all (D-430).
    func iss(_ t: String, _ o: String, _ r: String, _ k: IssueKind = .spelling, maybe: Bool = false) -> Issue {
        var i = Issue(range: (t as NSString).range(of: o), kind: k, message: "m", replacements: [r], original: o)
        i.tentative = maybe; return i
    }
    let para = "We recieved teh samples, to be clear, and they was late."
    let list = [iss(para, "recieved", "received"), iss(para, "teh", "the"), iss(para, "to be clear, ", "", .voice),
                iss(para, "they was", "they were", .grammar), iss(para, "late", "tardy", .grammar, maybe: true)]
    check("calm mode keeps spelling and grammar", Engine.calm(list).count == 3)
    check("calm mode hides style rules and maybes", !Engine.calm(list).contains { $0.kind == .voice || $0.tentative })
    let all = Engine.fixAll(list, in: NSRange(location: 0, length: (para as NSString).length), of: para)
    check("fix all fixes every sure mistake in one go", all?.text == "We received the samples, to be clear, and they were late.")
    check("fix all leaves style rules and maybes alone", all?.fixed.count == 3)
    let two = "Teh first line.\nTeh second line."
    let both = [iss(two, "Teh", "The"), Issue(range: NSRange(location: 16, length: 3), kind: .spelling, message: "m", replacements: ["The"], original: "Teh")]
    check("fix all stays inside the paragraph", Engine.fixAll(both, in: NSRange(location: 0, length: 16), of: two)?.text == "The first line.\n")
    check("fix all skips a mistake the writer already changed", Engine.fixAll([iss(para, "teh", "the")], in: NSRange(location: 0, length: 10), of: "We got it.") == nil)

    // Two of the same typo in one sentence are judged separately, each at its own place (Codex re-check).
    let twice = "I need to wieght the boxes and record their wieght."
    let first = (twice as NSString).range(of: "wieght")
    let second = (twice as NSString).range(of: "wieght", options: .backwards)
    check("same typo twice in a sentence gets two places", Spelling.sentence(around: first, in: twice)?.1 != Spelling.sentence(around: second, in: twice)?.1)
    let home = "The homestead is near our hom."
    let typo = (home as NSString).range(of: "hom.")
    check("the typo's own place is used, not an earlier word that contains it",
          Spelling.sentence(around: NSRange(location: typo.location, length: 3), in: home)?.1 == typo.location)


    // Privacy (Oct 19 2026): bank and payment pages are skipped by whole word, and only this account's engine gets text.
    check("a US bank page is skipped", MoneyPages.isMoneyPage("Chase Online - Sign in"))
    check("a UK bank page is skipped", MoneyPages.isMoneyPage("Barclays | Log in"))
    check("an old saved \u{201C}TD \u{201D} with a space still matches", MoneyPages.isMoneyPage("TD EasyWeb", words: ["TD "]))
    check("\u{201C}purchase\u{201D} is not Chase", !MoneyPages.isMoneyPage("Your purchase order - Google Docs"))
    check("an ordinary page is read", !MoneyPages.isMoneyPage("Quarterly plan - Google Docs"))
    check("an engine run by this account is trusted", LanguageTool.ownerIsMe("p1127\nu501\nf138\n", uid: 501))
    check("an engine run by another login is not", !LanguageTool.ownerIsMe("p1127\nu502\nf138\n", uid: 501))
    check("no engine seen is not trusted", !LanguageTool.ownerIsMe("", uid: 501))

    print(failed == 0 ? "safety checks: all pass" : "safety checks: \(failed) failed")
    if failed > 0 { exit(1) }
}

/// Mistakes whose right fix depends on the sentence (`--context`): the first suggestion must be the right word.
/// Tests/context_spelling.tsv: group, sentence, wrong words, right words.
@MainActor
func contextChecks() async {
    let file = CommandLine.arguments.contains("--heldout") ? "Tests/context_spelling_heldout.tsv" : "Tests/context_spelling.tsv"
    let tsv = try! String(contentsOfFile: file, encoding: .utf8)
    var right = 0, flagged = 0, total = 0
    for line in tsv.split(separator: "\n") {
        let f = line.split(separator: "\t").map(String.init)
        guard f.count >= 4 else { continue }
        total += 1
        let issues = await Engine.full(f[1], longform: false)
        let hit = issues.first { $0.original.localizedCaseInsensitiveContains(f[2]) || f[2].localizedCaseInsensitiveContains($0.original) }
        let first = hit?.replacements.first ?? "-"
        // Right when the sentence with the first suggestion applied reads as one of the expected fixes.
        let fixed = hit.map { (f[1] as NSString).replacingCharacters(in: $0.range, with: first) } ?? f[1]
        let words = Set(fixed.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }.map(String.init))
        let ok = hit != nil && f[3].split(separator: "|").contains { alt in
            let a = alt.lowercased().split(separator: " ").map(String.init)
            return a.count == 1 ? words.contains(a[0]) : fixed.lowercased().contains(alt.lowercased())
        }
        if hit != nil { flagged += 1 }
        if ok { right += 1 }
        print(ok ? "  pass" : hit == nil ? "  MISS" : "  WRONG", f[1], "->", hit.map { "\($0.original) -> \(first)" } ?? "not flagged")
    }
    // The live engine must pass the owner check and still answer (Oct 19 2026). Skipped when it isn't running.
    if LanguageTool.listenerIsMine() {
        let live = await LanguageTool.checkIfReady("They was late again.")
        print(live?.isEmpty == false ? "  pass the grammar engine on this Mac answers" : "  FAIL the grammar engine on this Mac answers")
    } else { print("  skip the grammar engine isn't running for this account") }
    print("context spelling: \(flagged)/\(total) flagged, \(right)/\(total) first suggestion right")
}

if CommandLine.arguments.contains("--context") { await contextChecks() }
else if CommandLine.arguments.contains("--safety") { safetyChecks() }
else if CommandLine.arguments.contains("--card") { cardChecks() }
else if CommandLine.arguments.contains("--email") { emailChecks() }
else if CommandLine.arguments.contains("--patterns") { patternsDemo() } else { await run() }
