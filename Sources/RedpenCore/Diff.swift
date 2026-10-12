import Foundation

/// Word-level diff between the original and the model's corrected copy.
enum Diff {
    struct Token { let text: String; let key: String; let range: NSRange }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { w, r, _, _ in
            guard let w else { return }
            out.append(Token(text: w, key: w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), range: NSRange(r, in: s)))
        }
        return out
    }

    static func edits(from original: String, to fixed: String) -> [Issue] {
        let a = tokens(original), b = tokens(fixed)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // A rewrite that changes most of the sentence is the model restyling, not correcting.
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].key == b[j].key ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        if Double(lcs[0][0]) < Double(n) * 0.6 { return [] }

        var out: [Issue] = []
        var i = 0, j = 0
        let ons = original as NSString, fns = fixed as NSString
        while i < n || j < m {
            if i < n, j < m, a[i].key == b[j].key { i += 1; j += 1; continue }
            let si = i, sj = j
            while (i < n || j < m) && !(i < n && j < m && a[i].key == b[j].key) {
                if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) { j += 1 } else { i += 1 }
            }
            // Anchor pure insertions to the word before (or after) so there is something to underline.
            var ai = si, aj = sj, bi = i, bj = j
            if ai == bi { if ai > 0 { ai -= 1; aj -= 1 } else if bi < n { bi += 1; bj += 1 } else { continue } }
            let oRange = NSRange(location: a[ai].range.location, length: NSMaxRange(a[bi - 1].range) - a[ai].range.location)
            let rep: String
            if aj < bj {
                rep = fns.substring(with: NSRange(location: b[aj].range.location, length: NSMaxRange(b[bj - 1].range) - b[aj].range.location))
            } else { rep = "" }
            let orig = ons.substring(with: oRange)
            if orig.caseInsensitiveCompare(rep) == .orderedSame { continue }
            out.append(Issue(range: oRange, kind: .grammar, message: rep.isEmpty ? "Cut \u{201C}\(orig)\u{201D}" : "Change to \u{201C}\(rep)\u{201D}", replacements: [rep], original: orig))
        }
        return out
    }
}
