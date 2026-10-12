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
        let file = a[i] == "--blind2" ? "Tests/blind2.tsv" : a[i] == "--blind-file" ? a[i + 1] : "Tests/blind.tsv"
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
            print("         [\(i.kind.rawValue)] \"\(i.original)\" -> \(i.replacements.first.map { "\"\($0)\"" } ?? "(flag)")  \(i.message)")
            if let l = Lessons.lesson(for: i) { print("           lesson \(l.id): \(l.rule)") }
        }
    }
    print("\nScore")
    for g in ["spelling", "grammar", "rules"] { let v = caught[g] ?? (0, 0); print("  \(g): \(v.0)/\(v.1)") }
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

if CommandLine.arguments.contains("--patterns") { patternsDemo() } else { await run() }
