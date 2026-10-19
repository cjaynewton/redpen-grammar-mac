import Foundation

/// Keeps Redpen's own files readable by this Mac account only, so another login on the same Mac can't open
/// your settings, your mistakes list or the log.
public enum Private {
    /// The folder in Application Support that holds settings, the mistakes list and the grammar engine.
    public static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Redpen", isDirectory: true)

    /// Owner-only: 0700 for a folder, 0600 for a file. Does nothing when the path doesn't exist.
    public static func lock(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: isDir.boolValue ? 0o700 : 0o600], ofItemAtPath: url.path)
    }

    /// Locks the folder and every file directly inside it, including older settings backups.
    public static func lockFolder() {
        lock(folder)
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where !f.hasDirectoryPath { lock(f) }
    }
}

/// Browser pages Redpen never reads, spotted by the window title: banks, card companies, brokers and payment apps.
public enum MoneyPages {
    public static let titleWords = [
        // Any bank
        "bank", "banks", "banking", "online banking", "credit union",
        // Canada
        "RBC", "Royal Bank", "TD", "EasyWeb", "Scotiabank", "BMO", "CIBC", "Tangerine", "Simplii", "Wealthsimple",
        "Questrade", "Desjardins", "National Bank", "EQ Bank", "Interac",
        // United States
        "Chase", "Wells Fargo", "Bank of America", "Citibank", "Capital One", "U.S. Bank", "PNC", "Truist",
        "Charles Schwab", "Schwab", "Fidelity", "Vanguard", "Robinhood", "E*TRADE", "Venmo", "Zelle", "Cash App",
        "Synchrony",
        // United Kingdom, Europe and Australia
        "Barclays", "HSBC", "Lloyds", "NatWest", "Santander", "Monzo", "Revolut", "Westpac", "ANZ", "NetBank",
        // Cards, payments and crypto
        "PayPal", "Amex", "American Express", "Mastercard", "Coinbase",
    ]

    /// True when the title contains one of `words` as a whole word, ignoring case, so "Chase" matches
    /// "Chase Online" but not "purchase". Spaces around a saved word are ignored.
    public static func isMoneyPage(_ title: String, words: [String] = titleWords) -> Bool {
        let t = title as NSString
        func letter(_ i: Int) -> Bool {
            guard i >= 0, i < t.length, let u = Unicode.Scalar(t.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u)
        }
        for raw in words {
            let w = raw.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { continue }
            var from = 0
            while from < t.length {
                let r = t.range(of: w, options: .caseInsensitive, range: NSRange(location: from, length: t.length - from))
                guard r.location != NSNotFound else { break }
                if !letter(r.location - 1), !letter(r.location + r.length) { return true }
                from = r.location + 1
            }
        }
        return false
    }
}
