import AppKit
import ApplicationServices
import ServiceManagement
import RedpenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PanelHost {
    private var status: NSStatusItem!
    private var watcher: Watcher!
    private let deep = DeepCheck()
    private var panel: MenuPanel!
    private let welcome = WelcomeWindow()
    private let settings = SettingsWindow()
    private var lastDeepText: String?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        Fonts.register()
        watcher = Watcher(config: Config.load())
        if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
            MenuPanel.render(host: self, to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-card"), i + 1 < CommandLine.arguments.count {
            var card = SuggestionPanel.Card(kind: "Grammar", color: IssueKind.grammar.color, marks: [("was", "were")],
                                            message: "For something that isn\u{2019}t true, use \u{201C}were\u{201D}: \u{201C}if I were\u{201D}, \u{201C}I wish it were\u{201D}.",
                                            why: nil, example: "If I were the buyer\u{2026} / The contract requires that he sign.")
            card.primary = .init(title: "Use \u{201C}were\u{201D}") {}
            card.footer = [.init(title: "Ignore") {}]
            for look in ["light", "dark"] { SuggestionPanel.render(card, appearance: look, to: "\(CommandLine.arguments[i + 1])-\(look).png") }
            exit(0)
        }
        // Debug: run a Deep check on a file and print Claude's reply. `--deep email draft.txt`
        if let i = CommandLine.arguments.firstIndex(of: "--deep"), i + 2 < CommandLine.arguments.count,
           let mode = DeepMode(rawValue: CommandLine.arguments[i + 1]),
           let text = try? String(contentsOfFile: CommandLine.arguments[i + 2], encoding: .utf8) {
            let c = watcher.config
            print(DeepCheck.call(claude: c.claudeExecutable, model: c.deepCheckModel, prompt: DeepPrompt.build(c.houseStyle, mode: mode), input: text))
            exit(0)
        }
        // Debug: download and start the grammar engine, check one sentence, print the result. `--install-engine`
        if CommandLine.arguments.contains("--install-engine") {
            let e = GrammarEngine.shared
            e.startIfInstalled()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if e.state == .missing { e.install() }
                var last = -1
                while true {
                    switch e.state {
                    case .running:
                        let found = await LanguageTool.check("She don't think the price will hold.")
                        print("running; flagged: " + found.map { ($0.message) }.joined(separator: " | "))
                        e.stop(); exit(0)
                    case .failed(let why): print("failed: " + why); exit(1)
                    case .downloading(let f): let pct = Int(f * 100); if pct / 10 != last { last = pct / 10; print("downloading \(pct)%") }
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return
        }
        panel = MenuPanel(host: self)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Redpen")
        status.button?.target = self
        status.button?.action = #selector(statusClicked)

        if !AXIsProcessTrusted() || !watcher.config.welcomed {
            welcome.onDone = { [weak self] in
                guard let self else { return }
                self.watcher.config.welcomed = true
                self.watcher.config.save()
            }
            welcome.show()
        }
        watcher.start()
        GrammarEngine.shared.startIfInstalled()
        hotKey = HotKey { [weak self] in self?.watcher.openNearest() }
        // Start at login by default, once; the menu toggle can turn it off and that choice sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func statusClicked() {
        guard let button = status.button else { return }
        // The focused field must be read before the panel takes focus away.
        if !panel.isShown { lastDeepText = watcher.textForDeepCheck() }
        panel.toggle(from: button)
    }

    // MARK: PanelHost

    var config: Config {
        get { watcher.config }
        set {
            watcher.config = newValue
            if !newValue.enabled { watcher.clear() }
        }
    }
    func statusLine() -> (text: String, live: Bool) { watcher.statusLine() }
    var canDeepCheck: Bool { lastDeepText != nil }
    func openSettings() { showSettings() }
    func allowAccessibility() { showWelcome() }
    /// Waits for the app you were typing in to take focus back, then opens the card at its cursor.
    func fixAtCursor() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watcher.openNearest() } }

    @objc func deepCheck() {
        guard let t = lastDeepText else { return }
        deep.run(text: t, config: watcher.config)
    }

    @objc func showSettings() {
        settings.show(config: watcher.config) { [weak self] c in
            self?.watcher.config = c
            if !c.enabled { self?.watcher.clear() }
        }
    }
    @objc func showWelcome() { welcome.show() }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ n: Notification) { GrammarEngine.shared.stop() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
