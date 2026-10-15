import Foundation
import RedpenCore

/// Settings live in ~/Library/Application Support/Redpen/config.json so they can be edited by hand.
struct Config: Codable {
    var enabled = true
    /// Apps Redpen never reads.
    var excludedApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                        "com.apple.Passwords"]
    /// Browser windows whose title contains one of these are never read (banking).
    var excludedTitleWords = ["bank", "banking", "RBC", "Royal Bank", "TD ", "EasyWeb", "Scotiabank", "BMO", "CIBC",
                              "Tangerine", "Simplii", "Wealthsimple", "Questrade", "PayPal", "Amex", "American Express",
                              "Desjardins", "National Bank", "EQ Bank", "Interac"]
    /// Long-form apps also get the container-word check. Any text over 600 characters gets it too.
    var longformApps = ["com.microsoft.Word", "com.apple.mail", "com.apple.iWork.Pages", "com.microsoft.Outlook",
                        "com.apple.TextEdit", "md.obsidian", "com.apple.Notes"]
    var terminalApps = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm"]
    /// Built on Chromium or Electron: these need accessibility switched on before they expose text.
    var chromiumApps = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
                        "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]
    /// Office hides document text until a screen reader asks for it.
    var officeApps = ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
                      "com.microsoft.onenote.mac"]
    var claudePath = "/opt/homebrew/bin/claude"
    /// The Claude Code to run: the set path if it works, else the places the official installer, Homebrew and npm put it.
    var claudeExecutable: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ([claudePath, home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"])
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? claudePath
    }
    var deepCheckModel = "opus"
    /// Optional style rules on top of grammar. All off by default.
    var houseStyle = HouseStyle()
    /// Set once the welcome window has been shown.
    var welcomed = false
    /// The fix card's look: "light", "dark" or "system" (follow the Mac). Light suits the white pages most writing happens on.
    var cardAppearance = "light"

    init() {}

    /// Missing keys fall back to defaults, so new settings never wipe an older file's edits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
        excludedTitleWords = try c.decodeIfPresent([String].self, forKey: .excludedTitleWords) ?? d.excludedTitleWords
        longformApps = try c.decodeIfPresent([String].self, forKey: .longformApps) ?? d.longformApps
        terminalApps = try c.decodeIfPresent([String].self, forKey: .terminalApps) ?? d.terminalApps
        chromiumApps = try c.decodeIfPresent([String].self, forKey: .chromiumApps) ?? d.chromiumApps
        officeApps = try c.decodeIfPresent([String].self, forKey: .officeApps) ?? d.officeApps
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        deepCheckModel = try c.decodeIfPresent(String.self, forKey: .deepCheckModel) ?? d.deepCheckModel
        houseStyle = try c.decodeIfPresent(HouseStyle.self, forKey: .houseStyle) ?? d.houseStyle
        welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? d.welcomed
        cardAppearance = try c.decodeIfPresent(String.self, forKey: .cardAppearance) ?? d.cardAppearance
    }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
        // Never overwrite a file that exists but failed to parse; a hand edit may have a typo.
        let c = Config()
        if !FileManager.default.fileExists(atPath: url.path) { c.save() }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.url)
    }
}
