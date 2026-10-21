import Foundation

/// "Clean up this paragraph" (Control-Option-C): takes out what voice typing left in that the writer never meant
/// to say. Spoken fillers ("um", "you know" between commas, "So" opening a sentence), doubled words ("the the"),
/// a phrase said twice ("I wanted to I wanted to"), and false starts ("I want, I need the file"), which only
/// Apple's on-device model is trusted to judge. It only ever removes words, plus the capital a new sentence
/// start needs. It never rewrites.
public enum Cleanup {
    public enum Reason: String, Sendable { case filler, doubled, falseStart, capital }

    public struct Change: Sendable, Equatable {
        public var range: NSRange
        public var replacement: String
        public var original: String
        public var reason: Reason
    }

    /// Every change for one paragraph, in reading order, none overlapping. False starts need Apple's model and
    /// are skipped without it.
    public static func changes(_ text: String, model: Bool = true) async -> [Change] {
        let ns = text as NSString
        var cuts = rules(text)
        if model { cuts = add(cuts, await falseStarts(text, around: cuts)) }
        return withCapitals(cuts, in: ns)
    }

    /// The paragraph with every change made.
    public static func apply(_ changes: [Change], to text: String) -> String {
        var out = text as NSString
        for c in changes.sorted(by: { $0.range.location > $1.range.location }) {
            out = out.replacingCharacters(in: c.range, with: c.replacement) as NSString
        }
        return out as String
    }

    // MARK: Rules

    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    /// Sounds that are never words in writing.
    static let sounds = re("\\b(?:u+m+|u+h+m*|e+r+m+|hmm+)\\b")
    /// Fillers that only count when set off by commas: "it was, you know, late", "could you, like, send it".
    static let commaFillers = re("(?<=, )(?:you know|like|I mean)(?=[,.?!])")
    /// Fillers that only count opening a sentence, with a comma: "Like, could you", "You know, the crew".
    static let openingFillers = re("\\b(?:you know|like|I mean|okay so|ok so|so)(?=, )")
    /// "So" opening the paragraph with no comma: "So I wanted to". "So far", "So much" and "So that" carry meaning.
    static let openingSo = re("\\bso(?= (?!(?:far|much|many|long|that|what|when|if|to|too|very|few|little)\\b)[A-Za-z])")
    /// The same word twice in a row. "had had", "that that" and a few others can be right.
    static let doubled = re("\\b([A-Za-z]+(?:['\u{2019}][A-Za-z]+)?)(\\s+)\\1\\b")
    static let rightTwice: Set<String> = ["had", "that", "is", "do", "bye", "ha", "no", "knock", "tut", "far", "very", "so", "now", "there"]
    /// A run of two to five words said twice in a row, with or without a comma: "I wanted to I wanted to".
    static let phraseTwice = re("\\b([A-Za-z']+(?: [A-Za-z']+){1,4}),? \\1\\b")

    /// Fillers, doubled words and repeated phrases: plain rules, on every Mac.
    public static func rules(_ text: String) -> [Change] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Change] = []
        func cut(_ r: NSRange, _ why: Reason) {
            out = add(out, [Change(range: r, replacement: "", original: ns.substring(with: r), reason: why)])
        }
        for m in phraseTwice.matches(in: text, range: full) {
            // The second copy and what joins it go; the first stays, so its capital stays too.
            let first = m.range(at: 1)
            // "If it rains, it rains, and": a comma repeat that ends its clause is said on purpose.
            if ns.substring(with: NSRange(location: NSMaxRange(first), length: 1)) == ",",
               NSMaxRange(m.range) >= ns.length || ",.;!?".contains(ns.substring(with: NSRange(location: NSMaxRange(m.range), length: 1))) { continue }
            cut(NSRange(location: NSMaxRange(first), length: NSMaxRange(m.range) - NSMaxRange(first)), .doubled)
        }
        for m in doubled.matches(in: text, range: full) where !rightTwice.contains(ns.substring(with: m.range(at: 1)).lowercased()) {
            let first = m.range(at: 1)
            cut(NSRange(location: NSMaxRange(first), length: NSMaxRange(m.range) - NSMaxRange(first)), .doubled)
        }
        // Fillers in reading order, so "Um, so I" sees "so" opening the sentence once "Um," is gone.
        var found: [(NSRange, Bool)] = []  // (words, only when opening a sentence)
        for m in sounds.matches(in: text, range: full) { found.append((m.range, false)) }
        for m in commaFillers.matches(in: text, range: full) { found.append((m.range, false)) }
        for m in openingFillers.matches(in: text, range: full) { found.append((m.range, true)) }
        for m in openingSo.matches(in: text, range: full) { found.append((m.range, true)) }
        for (r, opening) in found.sorted(by: { $0.0.location < $1.0.location }) {
            let starts = opensSentence(r.location, in: ns, removed: out.map(\.range))
            if opening && !starts { continue }
            // Mid-paragraph, "So the operators raised prices" means "therefore". Dictation puts "so" first.
            if ns.substring(with: r).lowercased() == "so", !opensSentence(r.location, in: ns, removed: out.map(\.range), paragraph: true) { continue }
            if let span = fillerSpan(r, in: ns, opening: starts) { cut(span, .filler) }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The filler plus the commas and spaces around it that must go with it, so the sentence reads cleanly.
    static func fillerSpan(_ r: NSRange, in ns: NSString, opening: Bool) -> NSRange? {
        let len = ns.length
        func ch(_ i: Int) -> Character? { i >= 0 && i < len ? Character(ns.substring(with: NSRange(location: i, length: 1))) : nil }
        let a = r.location, b = NSMaxRange(r)
        if opening {
            var j = b
            if ch(j) == "," { j += 1 }
            while let c = ch(j), c == " " { j += 1 }
            // A filler that is the whole sentence ("Um.") is left for the writer.
            guard let next = ch(j), next.isLetter || next.isNumber || next == "\"" || next == "\u{201C}" else { return nil }
            return NSRange(location: a, length: j - a)
        }
        if ch(a - 1) == " ", ch(a - 2) == "," {
            if ch(b) == "," { return NSRange(location: a - 2, length: b + 1 - (a - 2)) }      // "was, um, late"
            if let c = ch(b), ".?!".contains(c) { return NSRange(location: a - 2, length: b - (a - 2)) }  // "Friday, you know?"
            if ch(b) == " " { return NSRange(location: a, length: b + 1 - a) }
            return nil
        }
        if ch(a - 1) == " " {
            if ch(b) == ",", ch(b + 1) == " " { return NSRange(location: a - 1, length: b + 1 - (a - 1)) }  // "I um, need"
            if ch(b) == " " || ch(b).map({ ".?!".contains($0) }) == true { return NSRange(location: a - 1, length: b - (a - 1)) }
        }
        return nil
    }

    /// True when `loc` opens a sentence once the cuts in `removed` are made.
    /// With `paragraph`, only the start of the paragraph counts.
    static func opensSentence(_ loc: Int, in ns: NSString, removed: [NSRange], paragraph: Bool = false) -> Bool {
        var i = loc - 1
        while i >= 0 {
            if let r = removed.first(where: { NSLocationInRange(i, $0) }) { i = r.location - 1; continue }
            guard let c = UnicodeScalar(ns.character(at: i)) else { return false }
            if c == " " || c == "\t" { i -= 1; continue }
            return (paragraph ? "\n" : ".!?\n\u{201C}\"(").unicodeScalars.contains(c)
        }
        return true
    }

    /// Adds changes that do not overlap any already there.
    static func add(_ a: [Change], _ b: [Change]) -> [Change] {
        var out = a
        for c in b where !out.contains(where: { $0.range.overlaps(c.range) || ($0.range.length == 0 && c.range.location == $0.range.location) }) {
            out.append(c)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The capitals for a set of cuts, for drawing a preview without Apple's model.
    public static func withCapitalsPublic(_ cuts: [Change], in text: String) -> [Change] { withCapitals(cuts, in: text as NSString) }

    /// Where a cut leaves a sentence starting with a small letter, the letter gets its capital.
    static func withCapitals(_ cuts: [Change], in ns: NSString) -> [Change] {
        var out = cuts
        for c in cuts where c.reason != .capital && opensSentence(c.range.location, in: ns, removed: cuts.map(\.range)) {
            var j = NSMaxRange(c.range)
            while j < ns.length, let u = UnicodeScalar(ns.character(at: j)), u == " " { j += 1 }
            guard j < ns.length, !cuts.contains(where: { NSLocationInRange(j, $0.range) }) else { continue }
            let letter = ns.substring(with: NSRange(location: j, length: 1))
            guard letter != letter.uppercased(), letter.rangeOfCharacter(from: .lowercaseLetters) != nil else { continue }
            out = add(out, [Change(range: NSRange(location: j, length: 1), replacement: letter.uppercased(), original: letter, reason: .capital)])
        }
        return out
    }

    // MARK: False starts

    /// "I want, I need the file": a short start, a comma, then the same opening word and a different verb.
    /// Only a person or a question opens one; "The Stanford Daily, the student newspaper" is a description.
    /// Three in a row ("I came, I saw, I conquered") is a list, not a false start.
    static let restart = re("(?<![A-Za-z'\u{2019}] )\\b(I|we|you|they|he|she|it|can you|could you|can we|do you|is it|are you|will you|would you)( [A-Za-z'\u{2019}]+){1,2}, (\\1)( [A-Za-z'\u{2019}]+)")

    static func falseStarts(_ text: String, around cuts: [Change]) async -> [Change] {
        guard #available(macOS 26, *), AppleModel.isAvailable else { return [] }
        let ns = text as NSString
        var out: [Change] = []
        for m in restart.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location
            let restartAt = m.range(at: 3).location
            let fragment = NSRange(location: start, length: restartAt - start)
            guard !cuts.contains(where: { $0.range.overlaps(fragment) }) else { continue }
            // Must start a sentence or follow a comma, and the restart must not run into a third parallel clause.
            let before = ns.substring(to: start).trimmingCharacters(in: .whitespaces)
            guard before.isEmpty || ".!?,\n".contains(before.last!) else { continue }
            let after = ns.substring(from: restartAt)
            let lead = ns.substring(with: m.range(at: 1))
            if after.range(of: ", \(lead) ", options: .caseInsensitive) != nil { continue }
            let frag = ns.substring(with: fragment)
            let sentence = sentenceAround(m.range, in: ns)
            if await AppleModel.isFalseStart(sentence, fragment: frag.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) {
                out.append(Change(range: fragment, replacement: "", original: frag, reason: .falseStart))
            }
        }
        return out
    }

    static func sentenceAround(_ r: NSRange, in ns: NSString) -> String {
        var s = r.location
        while s > 0, let c = UnicodeScalar(ns.character(at: s - 1)), !".!?\n".unicodeScalars.contains(c) { s -= 1 }
        var e = NSMaxRange(r)
        while e < ns.length, let c = UnicodeScalar(ns.character(at: e)), !".!?\n".unicodeScalars.contains(c) { e += 1 }
        if e < ns.length { e += 1 }
        return ns.substring(with: NSRange(location: s, length: e - s)).trimmingCharacters(in: .whitespaces)
    }
}
