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
    // `--quick`: the instant layer only (Mac dictionary and the hand-written rules), for working on a rule.
    let quick = CommandLine.arguments.contains("--quick")
    if #available(macOS 26, *) { print("Apple model available:", AppleModel.isAvailable) } else { print("Apple model available: false (needs macOS 26)") }
    var caught: [String: (Int, Int)] = [:]
    var falsePos = 0
    var taught = 0, caughtTotal = 0
    var noLesson: [String] = []
    var ruleFlags = 0  // clean text flagged only by house-style rules (colons, container words): not an error
    var totalTime = 0.0
    for c in cases {
        let t = Date()
        let issues = quick ? Engine.quick(c.text, longform: true, style: .example) : await Engine.full(c.text, longform: true, style: .example)
        totalTime += Date().timeIntervalSince(t)
        let ns = c.text as NSString
        var hit = false
        if let e = c.expect {
            // The wrong words as whole words ("on" in "cartons on on" is the doubled one, not the one inside "cartons").
            let word = try! NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: e) + "(?![A-Za-z])")
            let er = word.firstMatch(in: c.text, range: NSRange(location: 0, length: ns.length))?.range ?? ns.range(of: e)
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
    check("not only... but also is flagged", Rules.check("We not only fix leaks but also clear drains.", longform: false, style: sets).contains { $0.kind == .voice && $0.original.lowercased() == "not only" })
    check("not only without a but stays quiet", Rules.check("This is not only mine. The rest is yours.", longform: false, style: sets).allSatisfy { $0.kind != .voice })
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

    // The mistakes list keeps 90 days (Oct 19 2026).
    let mURL = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-trim-\(UUID().uuidString).jsonl")
    let m = Mistakes(url: mURL)
    let now = Date()
    let recieve = Issue(range: NSRange(location: 0, length: 7), kind: .spelling, message: "", replacements: ["receive"], original: "recieve")
    for d in [1.0, 30, 89, 91, 400] { m.record(recieve, replacement: "receive", app: "test", at: now.addingTimeInterval(-d * 86_400)) }
    if let h = try? FileHandle(forWritingTo: mURL) { h.seekToEndOfFile(); h.write(Data("not a record\n".utf8)); try? h.close() }
    m.trim(now: now)
    check("fixes older than 90 days are dropped", m.all().count == 3)
    check("a line Redpen can't read is kept, not wiped", (try? String(contentsOf: mURL, encoding: .utf8))?.contains("not a record") == true)
    let perms = (try? FileManager.default.attributesOfItem(atPath: mURL.path)[.posixPermissions] as? Int) ?? 0
    check("the trimmed list stays owner-only", perms == 0o600)
    // A second Redpen trimming while the running one records must not drop fixes (Codex 0.6 review).
    let writer = Mistakes(url: mURL), trimmer = Mistakes(url: mURL)
    let recent = { writer.all().filter { $0.date >= now.addingTimeInterval(-86_400) }.count }
    let before = recent()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        for _ in 0..<300 {
            writer.record(recieve, replacement: "receive", app: "test", at: now)
            // An old fix each round, so every trim has something to drop and rewrites the file.
            writer.record(recieve, replacement: "receive", app: "test", at: now.addingTimeInterval(-200 * 86_400))
        }
    }
    DispatchQueue.global().async(group: group) { for _ in 0..<600 { trimmer.trim(now: now) } }
    group.wait()
    check("trimming in another copy never drops a new fix", recent() == before + 300)
    try? FileManager.default.removeItem(at: mURL)
    try? FileManager.default.removeItem(atPath: mURL.path + ".lock")

    // Deep check Replace: only ever where the checked text still sits, unchanged.
    let rPara = "Their going home now."
    let rDoc = "Dear Sam,\n\n\(rPara)\n\nThanks"
    let at = (rDoc as NSString).range(of: rPara)
    check("replace finds unchanged text in place", DeepReplace.locate(rPara, was: at, field: rDoc, in: rDoc) == .at(at))
    let typedAbove = "Hi again.\n" + rDoc
    check("replace refuses when anything else in the field changed", DeepReplace.locate(rPara, was: at, field: rDoc, in: typedAbove) == .changed)
    check("replace refuses text edited during the check",
          DeepReplace.locate(rPara, was: at, field: rDoc, in: rDoc.replacingOccurrences(of: "now", with: "soon")) == .changed)
    check("replace refuses a one-letter edit", DeepReplace.locate(rPara, was: at, field: rDoc, in: rDoc.replacingOccurrences(of: "home", with: "hone")) == .changed)
    // Two identical paragraphs; the checked first one is deleted mid-check. The copy must never be overwritten.
    let rTwice = "\(rPara)\n\n\(rPara)"
    let rFirst = NSRange(location: 0, length: (rPara as NSString).length)
    check("replace never moves to a copy after the checked text is deleted",
          DeepReplace.locate(rPara, was: rFirst, field: rTwice, in: String(rTwice.dropFirst((rPara as NSString).length + 2))) == .changed)
    check("replace refuses empty text", DeepReplace.locate("", was: NSRange(location: 0, length: 0), field: rDoc, in: rDoc) == .changed)
    check("replace refuses a deleted field", DeepReplace.locate(rPara, was: at, field: rDoc, in: "") == .changed)
    check("a normal reply can be put back", DeepReplace.wellFormed("REVISED\nFine.\n\nCHANGES\n- x\n\nNOTES\n- y"))
    check("a heading the AI corrected inside the text blocks Replace",
          !DeepReplace.wellFormed("REVISED\nPlan\nNOTES\nBring the samples.\n\nCHANGES\n- NTOES to NOTES"))
    check("a reply without CHANGES blocks Replace", !DeepReplace.wellFormed("REVISED\nPlan\nNOTES\nBring the samples."))
    check("a heading twice blocks Replace", !DeepReplace.wellFormed("REVISED\nA\nCHANGES\n- x\nCHANGES\n- y"))
    // Same text to Swift's ==, different positions to Accessibility: "é" against "e" plus an accent.
    let composed = String(repeating: "\u{E9}", count: 12) + "\nTheir home.\nTheir home."
    let decomposed = String(repeating: "e\u{301}", count: 12) + "\nTheir home.\nTheir home."
    let secondPara = NSRange(location: (composed as NSString).length - 11, length: 11)
    check("an accent written another way counts as a change",
          DeepReplace.locate("Their home.", was: secondPara, field: composed, in: decomposed) == .changed)
    check("text with its own NOTES line can't be replaced", DeepReplace.hasHeadingLine("Plan\nNOTES\nBring the samples.")
          && !DeepReplace.hasHeadingLine("These notes matter."))
    let padded = "  \(rPara)\n"
    check("checked range leaves out spaces and the line break",
          (padded as NSString).substring(with: DeepReplace.trimmed(NSRange(location: 0, length: (padded as NSString).length), in: padded)) == rPara)
    check("revised text is read from the reply",
          DeepReplace.revised(from: "REVISED\nThey're going home now.\n\nCHANGES\n- their to they're\n\nNOTES\n- none") == "They're going home now.")
    check("revised text stops at NOTES when there is no CHANGES",
          DeepReplace.revised(from: "REVISED\nFine.\n\nNOTES\n- Ask for a date.") == "Fine.")
    check("REVISED inside a sentence is not a heading", DeepReplace.revised(from: "I REVISED it.\nCHANGES\n- x") == nil)
    check("an error reply has no revised text", DeepReplace.revised(from: "Claude Code returned an error (exit 1).") == nil)
    check("revised keeps its paragraph breaks", DeepReplace.revised(from: "REVISED\nOne.\n\nTwo.\n\nCHANGES\n- x") == "One.\n\nTwo.")

    // Words written, for patterns per 1,000 words: only what the writer adds, never text already there.
    check("word count", WordLog.count("It's a well-known fact - 42 times, isn't it?") == 8)
    var g = WordGrowth()
    check("text already in a field isn't counted", g.added("one two three four five") == 0)
    check("typed words are counted", g.added("one two three four five six seven") == 2)
    check("deleting counts nothing", g.added("one two") == 0)
    check("retyped words count again", g.added("one two three") == 1)
    check("a pasted block isn't counted as writing", g.added("one two three " + String(repeating: "word ", count: 300)) == 0)
    check("typing after a paste counts from there", g.added("one two three " + String(repeating: "word ", count: 300) + "more") == 1)
    check("letters count as typing", WordGrowth.isTyping(keyCode: 0, characters: "a", command: false, control: false))
    check("space and Delete count as typing", WordGrowth.isTyping(keyCode: 49, characters: " ", command: false, control: false)
          && WordGrowth.isTyping(keyCode: 51, characters: "\u{7F}", command: false, control: false))
    check("a paste counts as typing", WordGrowth.isTyping(keyCode: 9, characters: "v", command: true, control: false))
    check("arrows don't count as typing", !WordGrowth.isTyping(keyCode: 125, characters: "\u{F701}", command: false, control: false))
    check("shortcuts don't count as typing", !WordGrowth.isTyping(keyCode: 31, characters: "o", command: true, control: false)
          && !WordGrowth.isTyping(keyCode: 53, characters: "\u{1B}", command: false, control: false))
    g.reset()
    check("a new field starts from its own text", g.added("a b c d e f g h") == 0)
    let wURL = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-words-\(UUID().uuidString).json")
    let wl = WordLog(url: wURL), wNow = Date()
    wl.add(120, at: wNow); wl.add(30, at: wNow); wl.add(500, at: wNow.addingTimeInterval(-100 * 86_400))
    wl.save(now: wNow)
    let saved = WordLog(url: wURL).all()
    check("word counts are saved, old ones dropped", saved.count == 1 && saved[0].words == 150)
    let other = WordLog(url: wURL)
    other.add(10, at: wNow); other.save(now: wNow)
    check("two copies saving add up", WordLog(url: wURL).all().first?.words == 160)
    let wPerm = (try? FileManager.default.attributesOfItem(atPath: wURL.path)[.posixPermissions] as? Int) ?? 0
    check("word counts file is owner-only", wPerm == 0o600)
    let wText = (try? String(contentsOf: wURL, encoding: .utf8)) ?? ""
    check("word counts file holds only numbers", wText.allSatisfy { "{}\":,0123456789".contains($0) })
    try? FileManager.default.removeItem(at: wURL)
    try? FileManager.default.removeItem(atPath: wURL.path + ".lock")

    // A fix written straight into the field is pasted as well only when the app ignored the write (review Oct 31 2026).
    // Before, any field that didn't read exactly as expected got the paste too, so a write the app accepted but
    // auto-corrected ("its" in, "it’s" shown) or applied a moment late ended up in the text twice.
    let wBefore = "The brand lost its shelf space.", wExpected = "The brand lost it's shelf space."
    check("a write that landed needs no paste", WriteCheck.outcome(before: wBefore, expected: wExpected, after: wExpected) == .written)
    check("a write the app ignored can be pasted", WriteCheck.outcome(before: wBefore, expected: wExpected, after: wBefore) == .untouched)
    check("a write the app auto-corrected is never pasted on top",
          WriteCheck.outcome(before: wBefore, expected: wExpected, after: "The brand lost it\u{2019}s shelf space.") == .unexpected)
    check("a write that landed twice is never pasted a third time",
          WriteCheck.outcome(before: wBefore, expected: wExpected, after: "The brand lost it'sit's shelf space.") == .unexpected)
    check("an unreadable field is never pasted into", WriteCheck.outcome(before: wBefore, expected: wExpected, after: nil) == .unexpected)
    check("an accent written another way counts as a change",
          WriteCheck.outcome(before: "caf\u{E9} its", expected: "caf\u{E9} it's", after: "cafe\u{301} its") == .unexpected)

    // "Our experts recommend" names its source; cutting it left "Our replacing the filter yearly." (review Oct 31 2026).
    var sourced = HouseStyle()
    sourced.starterSets = ["unsourced"]
    check("experts with an owner are a named source",
          Rules.check("Our experts recommend replacing the filter yearly.", longform: false, style: sourced).allSatisfy { $0.tip != "unsourced" })
    check("experts with no owner are still flagged",
          Rules.check("Experts say the filter lasts a year.", longform: false, style: sourced).contains { $0.tip == "unsourced" })

    // A settings file with a typo is copied aside before Redpen can save over it (review Oct 31 2026).
    let cDir = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-config-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: cDir, withIntermediateDirectories: true)
    let cURL = cDir.appendingPathComponent("config.json")
    let broken = Data(#"{"excludedApps": ["com.example.bank",], "calm": false}"#.utf8)
    try? broken.write(to: cURL)
    let kept = Private.keepUnreadable(cURL)
    check("an unreadable settings file is copied aside", kept.flatMap { FileManager.default.contents(atPath: $0.path) } == broken)
    check("the copy sits beside it with its own name", kept?.lastPathComponent.hasPrefix("config.unreadable-") == true && kept?.pathExtension == "json")
    let cPerm = kept.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? Int } ?? 0
    check("the copy is owner-only", cPerm == 0o600)
    check("the same broken file is copied only once", Private.keepUnreadable(cURL) == nil)
    check("no file, no copy", Private.keepUnreadable(cDir.appendingPathComponent("missing.json")) == nil)
    try? FileManager.default.removeItem(at: cDir)

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

/// Style tips on finished writing (`--tips file.tsv ...`, add `--show` to print each mark): how many paragraphs each
/// tip marks, so a noisy tip shows up. Every tip on; LanguageTool supplies the Hidden doer tip when it is running.
@MainActor
func tipNoise() async {
    let a = CommandLine.arguments
    let files = a.indices.filter { a[$0] == "--tips" || (a[$0].hasSuffix(".tsv") && $0 > 0) }.compactMap { i -> String? in
        a[i] == "--tips" ? nil : a[i] }
    let show = a.contains("--show")
    // Default settings plus every tip: the writer's own lists would otherwise claim some of the same words.
    var style = HouseStyle()
    style.tips = StyleTip.all.map(\.id)
    let ltOn = await LanguageTool.isRunning()
    print("LanguageTool running:", ltOn)
    var totals: [String: (paras: Int, marks: Int)] = [:]
    var paraTotal = 0
    for file in files {
        let tsv = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let rows = tsv.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count > 1 && ($0.count < 3 || $0[2].isEmpty) }
        var per: [String: (paras: Int, marks: Int)] = [:]
        for r in rows {
            let text = r[1]
            var found = Rules.check(text, longform: true, style: style).filter { $0.tip != nil }
            if ltOn { found += await LanguageTool.check(text, enabling: StyleTip.languageToolRules(style.tips)).filter { $0.tip != nil } }
            found = Engine.outsideQuotes(found, in: text)
            for id in Set(found.compactMap(\.tip)) {
                let n = found.filter { $0.tip == id }.count
                var v = per[id] ?? (0, 0); v.paras += 1; v.marks += n; per[id] = v
            }
            if show { for i in found { print("  [\(i.tip!)] \"\(i.original)\" -> \(i.replacements.first.map { "\"\($0)\"" } ?? "(flag)")   | \(text.prefix(140))") } }
        }
        print("\n\(file.split(separator: "/").last!) (\(rows.count) finished paragraphs)")
        for t in StyleTip.all {
            let v = per[t.id] ?? (0, 0)
            print("  \(t.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(v.paras) paragraphs, \(v.marks) marks")
            var tv = totals[t.id] ?? (0, 0); tv.paras += v.paras; tv.marks += v.marks; totals[t.id] = tv
        }
        paraTotal += rows.count
    }
    print("\nAll sets (\(paraTotal) paragraphs)")
    for t in StyleTip.all {
        let v = totals[t.id] ?? (0, 0)
        print(String(format: "  %@ %3d paragraphs (%.1f%%), %3d marks", t.id.padding(toLength: 10, withPad: " ", startingAt: 0), v.paras,
                     paraTotal == 0 ? 0 : 100 * Double(v.paras) / Double(paraTotal), v.marks))
    }
}

/// Style tips (`--tips-check`): every example in the app is caught by its own tip, every rewrite is left alone,
/// and the settings, calm mode and cuts behave.
@MainActor
func tipChecks() async {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { failed += 1 } }
    let ltOn = await LanguageTool.isRunning()
    func found(_ text: String, _ tip: String) async -> [Issue] {
        var style = HouseStyle(); style.tips = [tip]
        var all = Rules.check(text, longform: false, style: style).filter { $0.tip == tip }
        if tip == "passive" { all += await LanguageTool.check(text, enabling: StyleTip.languageToolRules(style.tips)).filter { $0.tip == tip } }
        return all
    }
    for tip in StyleTip.all {
        guard let ex = TipExamples.of(tip.id) else { check("\(tip.id) has examples", false); continue }
        check("\(tip.id) has 3 or 4 examples", (3...4).contains(ex.pairs.count))
        if tip.id == "passive" && !ltOn { print("  skip passive examples, LanguageTool isn't running"); continue }
        for pair in ex.pairs {
            let before = pair.beforeRuns.map(\.0).joined(), after = pair.afterRuns.map(\.0).joined()
            var at = 0, marked = NSRange(location: 0, length: 0)
            for (t, m) in pair.beforeRuns { let n = (t as NSString).length; if m { marked = NSRange(location: at, length: n) }; at += n }
            let hit = await found(before, tip.id).contains { $0.range.overlaps(marked) }
            check("\(tip.id) catches: \(before)", hit)
            check("\(tip.id) leaves the rewrite alone: \(after)", await found(after, tip.id).isEmpty)
        }
        let text = [ex.why, ex.leaveWhen] + ex.pairs.flatMap { [$0.before, $0.after] }
        check("\(tip.id) examples have no em dashes", !text.joined().contains("\u{2014}"))
    }
    // Near misses each tip must leave alone.
    for (tip, text) in [("softeners", "What kind of roof do you have?"), ("softeners", "This sort of job takes two days."),
                        ("softeners", "I think about it every day."), ("filler", "I just finished the deck."),
                        ("filler", "As you know, the price went up."), ("filler", "It was actually cheaper to rebuild."),
                        ("unsourced", "Our research shows a gap in the market."), ("promises", "The loan is guaranteed by the bank."),
                        ("promises", "It is the best time to book."), ("nominal", "The decision is yours."),
                        ("apology", "We are sorry to see you go."), ("slowstart", "We wanted to reach out to new customers this spring."),
                        ("twice", "The account is past due.")] {
        check("\(tip) leaves alone: \(text)", await found(text, tip).isEmpty)
    }
    // Cuts read cleanly.
    func cutText(_ text: String, _ tip: String) async -> String? {
        guard let i = await found(text, tip).first, let r = i.replacements.first else { return nil }
        return (text as NSString).replacingCharacters(in: i.range, with: r)
    }
    check("cut mid-sentence", await cutText("I basically need the quote.", "filler") == "I need the quote.")
    check("cut between commas", await cutText("It was, you know, late.", "filler") == "It was late.")
    check("cut before a question mark", await cutText("Can you send it Friday, you know?", "filler") == "Can you send it Friday?")
    check("cut at the start capitalises the next word", await cutText("I think the price is fair.", "softeners") == "The price is fair.")
    check("verb noun keeps the tense", await cutText("We made a decision on Monday.", "nominal") == "We decided on Monday.")
    check("verb noun keeps the capital", await cutText("Make a decision today.", "nominal") == "Decide today.")
    check("a passive that names the doer is left alone", ltOn ? await found("The invoice was sent by our office on Monday.", "passive").isEmpty : true)
    check("a passive with a doer-free verb is left alone", ltOn ? await found("The store was built in 1952.", "passive").isEmpty : true)

    // Settings from 0.8 keep what they had on.
    let old = try? JSONDecoder().decode(HouseStyle.self, from: Data(#"{"starterSets":["plain","hedging","ai"]}"#.utf8))
    check("0.8 settings keep their tips, hedging becomes softeners", old?.tips == ["plain", "softeners", "ai"])
    check("new settings have every tip off", HouseStyle().tips.isEmpty)
    // Calm mode hides house rules but keeps a tip the writer switched on.
    var tipIssue = Issue(range: NSRange(location: 0, length: 5), kind: .voice, message: "m", replacements: [], original: "maybe")
    tipIssue.tip = "softeners"
    let rule = Issue(range: NSRange(location: 6, length: 1), kind: .voice, message: "No em dashes.", replacements: [], original: "x")
    check("calm mode keeps a switched-on tip", Engine.calm([tipIssue, rule]) == [tipIssue])
    check("fix all never applies a tip", Engine.fixAll([tipIssue], in: NSRange(location: 0, length: 5), of: "maybe") == nil)
    check("a tip has its own lesson, for Your patterns", Lessons.lesson(for: tipIssue)?.id == "tip-softeners")
    check("deep check is told about switched-on tips", DeepPrompt.build({ var s = HouseStyle(); s.tips = ["filler"]; return s }(), mode: .fixOnly).contains("filler words"))
    print(failed == 0 ? "tip checks: all pass" : "tip checks: \(failed) failed")
    if failed > 0 { exit(1) }
}

/// Clean up this paragraph (`--cleanup`): Tests/cleanup.tsv holds dictated sentences with the text they should
/// become, and finished sentences that must come out unchanged. `--no-model` skips Apple's model (false starts).
@MainActor
func cleanupChecks() async {
    var model = !CommandLine.arguments.contains("--no-model")
    if #available(macOS 26, *) { model = model && AppleModel.isAvailable } else { model = false }
    print("Apple model used for false starts:", model)
    // `--cleanup a.tsv b.tsv`: finished paragraphs from other sets, none of which should change.
    let others = CommandLine.arguments.filter { $0.hasSuffix(".tsv") }
    if !others.isEmpty {
        var n = 0, changed = 0
        for file in others {
            for line in ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count > 1, f.count < 3 || f[2].isEmpty else { continue }
                n += 1
                let found = await Cleanup.changes(f[1], model: model)
                if !found.isEmpty {
                    changed += 1
                    print("  CHANGED", found.map { "[\($0.reason.rawValue): \"\($0.original)\"]" }.joined(separator: " "), "|", f[1].prefix(160))
                }
            }
        }
        print("clean up on finished paragraphs: \(changed)/\(n) changed")
        return
    }
    let tsv = try! String(contentsOfFile: "Tests/cleanup.tsv", encoding: .utf8)
    var right = 0, dictated = 0, changes = 0, cleanChanged = 0, clean = 0
    for line in tsv.split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 2 else { continue }
        let found = await Cleanup.changes(f[1], model: model)
        let out = Cleanup.apply(found, to: f[1])
        let cuts = found.filter { $0.reason != .capital }
        if f[0] == "clean" {
            clean += 1
            if out != f[1] { cleanChanged += 1 }
            print(out == f[1] ? "  same   " : "  CHANGED", f[1], out == f[1] ? "" : "-> \(out)")
        } else {
            dictated += 1; changes += cuts.count
            if out == f[2] { right += 1 }
            print(out == f[2] ? "  right  " : "  WRONG  ", f[1], "->", out, out == f[2] ? "" : "(wanted: \(f[2]))",
                  cuts.map { "[\($0.reason.rawValue): \"\($0.original)\"]" }.joined(separator: " "))
        }
    }
    print("clean up: \(right)/\(dictated) dictated sentences come out right, \(changes) words or phrases taken out")
    print("clean up: \(cleanChanged)/\(clean) finished sentences changed")
}

/// Your patterns per 1,000 words written (`--rates`): a light writing week must never look like progress.
func rateChecks() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { failed += 1 } }
    let now = Date(), day = 86_400.0
    func fix(_ daysAgo: Double, _ lesson: String = "its-its") -> MistakeRecord {
        MistakeRecord(date: now.addingTimeInterval(-daysAgo * day), lesson: lesson, title: "its and it's", original: "its", replacement: "it's", app: "test")
    }
    func words(_ perWeek: [Int]) -> [(date: Date, words: Int)] {  // oldest first, the last is this week; logged early in each week
        perWeek.enumerated().map { i, n in (now.addingTimeInterval(-Double(perWeek.count - 1 - i) * 7 * day - 6.5 * day), n) }
    }
    // Four weeks of 2 fixes in 1,000 words, then a quiet week: 1 fix in 200 words.
    /// `perWeek` fixes in each of the `weeks` weeks before this one.
    func earlier(_ perWeek: Int, weeks: Int = 4) -> [MistakeRecord] {
        var out: [MistakeRecord] = []
        for w in 1...weeks { for k in 0..<perWeek { out.append(fix(Double(w) * 7 + 1 + Double(k) * 2)) } }
        return out
    }
    var recs: [MistakeRecord] = earlier(2) + [fix(1)]
    var s = PatternSummary(recs, words: words([1000, 1000, 1000, 1000, 200]), now: now)
    check("quiet week is not called progress", s.rows.first?.trend == "too little writing to compare")
    check("quiet week gets no rate", s.rateThisWeek == nil && s.rateLine == "Not enough writing this week for a rate per 1,000 words")
    // Same counts, normal writing: 1 fix in 1,000 words is down from 2.
    s = PatternSummary(recs, words: words([1000, 1000, 1000, 1000, 1000]), now: now)
    check("fewer fixes in the same writing is down", s.rows.first?.trend == "1 per 1,000 words, down from 2")
    check("rate line shows this week and last", s.rateLine == "1 per 1,000 words you wrote, 2 the week before")
    // Same fixes as usual but twice the writing: the rate halves, the raw count would say "about the same".
    recs = earlier(2) + [fix(1), fix(3)]
    s = PatternSummary(recs, words: words([1000, 1000, 1000, 1000, 2000]), now: now)
    check("same count in more writing is down", s.rows.first?.trend == "1 per 1,000 words, down from 2")
    // More fixes per word: up.
    recs = earlier(1) + [fix(1), fix(2), fix(3)]
    s = PatternSummary(recs, words: words([1000, 1000, 1000, 1000, 1000]), now: now)
    check("more fixes per word is up", s.rows.first?.trend == "3 per 1,000 words, up from 1")
    check("rate shows one decimal", PatternSummary.format(2.46) == "2.5" && PatternSummary.format(3.0) == "3")
    // Before Redpen counted words: the old count trend, and no rate line.
    recs = earlier(2) + [fix(1)]
    s = PatternSummary(recs, now: now)
    check("without word counts the old trend stays", s.rows.first?.trend == "down from about 2 a week" && s.rateLine == nil)
    // Counting began this week: fixes from before have no words, so no rate comparison and no false "down".
    s = PatternSummary(recs, words: [(now.addingTimeInterval(-2 * day), 1500)], now: now)
    check("fixes from before counting began aren't compared", s.rows.first?.trend == "too little writing to compare")
    check("first counted week has a rate", s.rateThisWeek.map { PatternSummary.format($0) } == "0.7")
    // Words at 12:50 and a fix at 12:51 a week ago, now 12:45: both belong to the same week.
    let cal = Calendar(identifier: .gregorian)
    var parts = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
    parts.minute = 45; parts.second = 0; parts.nanosecond = 0
    let at1245 = cal.date(from: parts)!
    let wk = at1245.addingTimeInterval(-7 * day)
    let fixAt = MistakeRecord(date: wk.addingTimeInterval(6 * 60), lesson: "its-its", title: "its", original: "its", replacement: "it's", app: "test")
    let edge = PatternSummary([fixAt], words: [(wk.addingTimeInterval(5 * 60), 400)], now: at1245)
    let fixWeek = edge.rows.first?.weeks.firstIndex { $0 > 0 }, wordWeek = edge.words.firstIndex { $0 > 0 }
    check("words and fixes from one sitting land in the same week", fixWeek != nil && fixWeek == wordWeek)
    // Terminal fixes show in the counts but not the rates, since Terminal writing isn't counted.
    let term = MistakeRecord(date: now.addingTimeInterval(-day), lesson: "its-its", title: "its", original: "its", replacement: "it's", app: "com.apple.Terminal")
    let withTerm = PatternSummary([term, term, term], words: words([1000]), uncounted: ["com.apple.Terminal"], now: now)
    check("terminal fixes stay out of the rate", withTerm.thisWeek == 3 && withTerm.rateThisWeek == 0)
    print(failed == 0 ? "rate checks: all pass" : "rate checks: \(failed) failed")
    if failed > 0 { exit(1) }
}

if CommandLine.arguments.contains("--rates") { rateChecks() }
else if CommandLine.arguments.contains("--cleanup") { await cleanupChecks() }
else if CommandLine.arguments.contains("--tips-check") { await tipChecks() }
else if CommandLine.arguments.contains("--tips") { await tipNoise() }
else if CommandLine.arguments.contains("--context") { await contextChecks() }
else if CommandLine.arguments.contains("--safety") { safetyChecks() }
else if CommandLine.arguments.contains("--card") { cardChecks() }
else if CommandLine.arguments.contains("--email") { emailChecks() }
else if CommandLine.arguments.contains("--patterns") { patternsDemo() } else { await run() }
