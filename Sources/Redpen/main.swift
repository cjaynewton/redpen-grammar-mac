import AppKit
import Carbon.HIToolbox
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
    private var lastDeepText: String?
    private var hotKey: HotKey?
    private var fixAllKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        Fonts.register()
        watcher = Watcher(config: Config.load())
        Private.lockFolder()
        Mistakes.shared.trim()
        if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
            MenuPanel.render(host: self, to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
            MenuPanel.render(host: self, to: CommandLine.arguments[i + 1], pages: [.settings, .fixBox, .advanced, .styleTips, .about])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-card"), i + 1 < CommandLine.arguments.count {
            let card = SuggestionPanel.sample
            // Crowded: long alternatives, a dictionary link and a count, which must wrap rather than cut words short.
            var long = SuggestionPanel.Card(kind: "Spelling", color: IssueKind.spelling.color, marks: [("controversal", "controversial")],
                                            message: nil, why: nil, example: nil, count: 4)
            long.primary = .init(title: "Use \u{201C}controversial\u{201D}") {}
            long.alts = ["contentious", "controversially", "conversational"].map { t in .init(title: t) {} }
            long.ignore = .init(title: "Ignore") {}
            long.footer = [.init(title: "Add to dictionary") {}]
            long.fixAll = (5, .init(title: "Fix all 5") {})
            long.position = (3, 12); long.onStep = { _ in }
            long.title = "Misspelled word"
            let ls = "It was a controversal call."
            long.sentence = (ls, (ls as NSString).range(of: "controversal"), "controversial")
            // A deletion and the Terminal card (which never takes keys, so shows no key hints).
            var cut = SuggestionPanel.Card(kind: "Grammar", color: IssueKind.grammar.color, marks: [("very", "Cut it")],
                                           message: "Drop the extra word.", why: nil, example: nil)
            cut.primary = .init(title: "Cut it") {}
            cut.ignore = .init(title: "Ignore") {}
            cut.title = "Extra word"
            let cs = "This is very very good."
            cut.sentence = (cs, NSRange(location: 8, length: 5), "")
            var term = SuggestionPanel.Card(kind: "Terminal", color: IssueKind.spelling.color, marks: [("teh", "the"), ("recieved", "received")],
                                            message: nil, why: nil, example: nil)
            term.primary = .init(title: "Fix all 2") {}
            term.ignore = .init(title: "Ignore") {}
            term.takesKeys = false
            // A warning with no suggestion: the words are marked, never struck.
            var flag = SuggestionPanel.Card(kind: "Your rules", color: IssueKind.voice.color, marks: [("leverage", nil)],
                                            message: "A vague word. Say what you will actually do.", why: nil, example: nil)
            flag.ignore = .init(title: "Ignore") {}
            flag.title = "One of your rules"
            let fs = "We can leverage the new carrier."
            flag.sentence = (fs, (fs as NSString).range(of: "leverage"), nil)
            // A style tip: its group in the label, Stop these tips, and its examples closed and open.
            let ts = "Studies show that customers prefer quotes sent the same day."
            let tipIssue = StyleTip.find("unsourced")!
            var tip = SuggestionPanel.Card(kind: "Style tip \u{00B7} Clear", color: IssueKind.voice.color,
                                           marks: [("Studies show that customers", "Customers")], message: tipIssue.message, why: nil, example: nil)
            tip.primary = .init(title: "Use \u{201C}Customers\u{201D}") {}
            tip.ignore = .init(title: "Ignore") {}
            tip.stop = .init(title: "Stop these tips") {}
            tip.examples = TipExamples.of("unsourced")
            tip.title = tipIssue.name
            tip.sentence = (ts, (ts as NSString).range(of: "Studies show that customers"), "Customers")
            for (name, c) in [("main", card), ("long", long), ("cut", cut), ("term", term), ("flag", flag), ("tip", tip)] {
                for style in ["roomy", "sentence", "keyboard"] {
                    for look in ["light", "dark"] {
                        SuggestionPanel.render(c, appearance: look, style: style, to: "\(CommandLine.arguments[i + 1])-\(name)-\(style)-\(look).png")
                        if name == "tip" {
                            SuggestionPanel.render(c, appearance: look, style: style, examples: true,
                                                   to: "\(CommandLine.arguments[i + 1])-tipopen-\(style)-\(look).png")
                        }
                    }
                }
            }
            exit(0)
        }
        // Debug: run a Deep check on a file and print the reply. `--deep email draft.txt`
        if let i = CommandLine.arguments.firstIndex(of: "--deep"), i + 2 < CommandLine.arguments.count,
           let mode = DeepMode(rawValue: CommandLine.arguments[i + 1]),
           let text = try? String(contentsOfFile: CommandLine.arguments[i + 2], encoding: .utf8) {
            var c = watcher.config
            // `--with chatgpt` and `--speed fast` try another helper without touching the settings file.
            if let w = CommandLine.arguments.firstIndex(of: "--with"), w + 1 < CommandLine.arguments.count { c.deepCheckWith = CommandLine.arguments[w + 1] }
            if let w = CommandLine.arguments.firstIndex(of: "--speed"), w + 1 < CommandLine.arguments.count { c.deepCheckSpeed = CommandLine.arguments[w + 1] }
            print(DeepCheck.call(DeepCheck.job(c, prompt: DeepPrompt.build(c.houseStyle, mode: mode), input: text)))
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
        Updates.shared.start()
        hotKey = HotKey { [weak self] in self?.watcher.openNearest() }
        fixAllKey = HotKey(id: 2, modifiers: controlKey | optionKey | shiftKey, name: "Control-Option-Shift-R") { [weak self] in
            self?.watcher.fixAllAtCursor()
        }
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
        watcher.panel.hide()  // the fix card and its keys never stay open behind Redpen's menu
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
    func allowAccessibility() { showWelcome() }
    /// Waits for the app you were typing in to take focus back, then opens the card at its cursor.
    func fixAllAtCursor() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watcher.fixAllAtCursor() } }
    func fixAtCursor() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watcher.openNearest() } }

    @objc func deepCheck() {
        guard let t = lastDeepText else { return }
        deep.run(text: t, config: watcher.config)
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
