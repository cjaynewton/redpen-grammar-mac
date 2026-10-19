import Foundation
import RedpenCore

/// Settings live in ~/Library/Application Support/Redpen/config.json so they can be edited by hand.
struct Config: Codable {
    var enabled = true
    /// Apps Redpen never reads.
    var excludedApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                        "com.apple.Passwords"]
    /// Browser windows whose title names a bank, card company, broker or payment app are never read.
    var excludedTitleWords = MoneyPages.titleWords
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
    /// The model name passed to Claude Code. Set from `deepCheckSpeed`; kept so older files still load.
    var deepCheckModel = "opus"
    /// Who Deep check asks: "claude" (Claude Code), "chatgpt" (Codex), "gemini" (Antigravity CLI), or "auto",
    /// the first of those that is signed in. Each runs on the writer's own plan through its official command-line
    /// tool. New users start on "auto"; older settings files without this choice keep Claude.
    var deepCheckWith = "auto"
    /// "fast" or "best"; "fable" is Claude only, for plans that include it. "custom" keeps a model name set by hand
    /// in an older settings file until Speed is changed. New users start on Fast: a few seconds feels like a tool.
    var deepCheckSpeed = "fast"
    /// The Claude Code model for the chosen speed.
    var claudeModel: String {
        switch deepCheckSpeed {
        case "fast": "sonnet"
        case "fable": "fable"
        case "custom": deepCheckModel
        default: "opus"
        }
    }
    /// Shown in menus and messages: "Claude", "ChatGPT" or "Gemini".
    var deepCheckName: String { Config.name(deepCheckWith) }
    static func name(_ who: String) -> String { who == "chatgpt" ? "ChatGPT" : who == "gemini" ? "Gemini" : "Claude" }
    /// The company that receives the text when Deep check uses this helper.
    static func company(_ who: String) -> String { who == "chatgpt" ? "OpenAI" : who == "gemini" ? "Google" : "Anthropic" }

    /// The helper Deep check will use: the chosen one, or on "auto" the first signed in of Claude, ChatGPT, Gemini.
    /// The sign-in checks start helper programs, so call this off the main thread.
    nonisolated func resolvedDeepWith() -> String {
        guard deepCheckWith == "auto" else { return deepCheckWith }
        if case .connected = Helpers.claude(path: claudeExecutable) { return "claude" }
        if case .connected = Helpers.codex() { return "chatgpt" }
        if case .connected = Helpers.gemini() { return "gemini" }
        return "claude"
    }

    /// Spelling for a new user, from the Mac's region: Canada, the US and the UK get their own; elsewhere any English.
    static var regionSpelling: String {
        switch Locale.current.region?.identifier {
        case "CA": "en_CA"
        case "US": "en_US"
        case "GB": "en_GB"
        default: ""
        }
    }
    /// Codex and the Antigravity CLI, wherever their installers put them.
    var codexExecutable: String? { Config.firstExecutable("codex") }
    var geminiExecutable: String? { Config.firstExecutable("agy") }
    static func firstExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/", "/usr/local/bin/", home + "/.local/bin/", home + "/.antigravity/bin/"]
            .map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// Optional style rules on top of grammar. All off by default.
    var houseStyle = HouseStyle()
    /// Set once the welcome window has been shown.
    var welcomed = false
    /// The fix card's look: "light", "dark" or "system" (follow the Mac). Light suits the white pages most writing happens on.
    var cardAppearance = "light"
    /// The fix card's layout: "roomy" (the note, large), "sentence" (the whole sentence with the fix in place)
    /// or "keyboard" (Return accepts, Esc skips, Tab moves on).
    var cardStyle = "roomy"
    /// Calm mode: underline only sure spelling and grammar mistakes. On for new users; people who set Redpen up
    /// before calm mode existed keep seeing everything until they switch.
    var calm = true

    init() {}

    /// Missing keys fall back to defaults, so new settings never wipe an older file's edits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        // Privacy lists keep what a file added and gain every entry a newer version adds, so an older
        // settings file never misses a newly protected app or bank.
        excludedApps = Config.merged(try c.decodeIfPresent([String].self, forKey: .excludedApps), d.excludedApps)
        excludedTitleWords = Config.merged(try c.decodeIfPresent([String].self, forKey: .excludedTitleWords), d.excludedTitleWords)
        longformApps = try c.decodeIfPresent([String].self, forKey: .longformApps) ?? d.longformApps
        terminalApps = try c.decodeIfPresent([String].self, forKey: .terminalApps) ?? d.terminalApps
        chromiumApps = try c.decodeIfPresent([String].self, forKey: .chromiumApps) ?? d.chromiumApps
        officeApps = try c.decodeIfPresent([String].self, forKey: .officeApps) ?? d.officeApps
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        deepCheckModel = try c.decodeIfPresent(String.self, forKey: .deepCheckModel) ?? d.deepCheckModel
        deepCheckWith = try c.decodeIfPresent(String.self, forKey: .deepCheckWith) ?? "claude"
        // Files from before the Speed choice keep the model they had.
        deepCheckSpeed = try c.decodeIfPresent(String.self, forKey: .deepCheckSpeed)
            ?? (["sonnet": "fast", "fable": "fable", "opus": "best"][deepCheckModel] ?? "custom")
        houseStyle = try c.decodeIfPresent(HouseStyle.self, forKey: .houseStyle) ?? d.houseStyle
        welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? d.welcomed
        cardAppearance = try c.decodeIfPresent(String.self, forKey: .cardAppearance) ?? d.cardAppearance
        cardStyle = try c.decodeIfPresent(String.self, forKey: .cardStyle) ?? d.cardStyle
        calm = try c.decodeIfPresent(Bool.self, forKey: .calm) ?? !welcomed
    }

    static func merged(_ saved: [String]?, _ defaults: [String]) -> [String] {
        guard let saved else { return defaults }
        let have = Set(saved.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return saved + defaults.filter { !have.contains($0.lowercased()) }
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
        var c = Config()
        if !FileManager.default.fileExists(atPath: url.path) {
            c.houseStyle.spelling = regionSpelling
            c.save()
        }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.url)
        Private.lock(Config.url)
    }
}
