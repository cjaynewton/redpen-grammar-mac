import AppKit
import RedpenCore

/// Sends text to Claude, ChatGPT or Gemini through each one's official command-line tool (Claude Code, Codex,
/// Antigravity CLI), so it runs on the writer's own plan, not an API key. Arguments go straight to the program,
/// never through a shell.
@MainActor
final class DeepCheck {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var note: NSTextField?
    private var replaceButton: NSButton?
    private var copyButton: NSButton?
    private var setupRow: NSStackView?
    private var getButton: NSButton?
    private var testButton: NSButton?

    private var target: Watcher.DeepTarget?
    private weak var watcher: Watcher?
    private var lastConfig: Config?
    private var mode: DeepMode = .fixOnly
    private var modePicker: NSSegmentedControl?
    private var request = 0
    /// The revised text from the newest answer, if it had one.
    private var revised: String?
    /// Set once Replace has put an answer in, so a second press can't put it in twice.
    private var replaced = false
    /// The helper the newest request went to ("claude", "chatgpt", "gemini"), for the setup link and the test.
    private var helper = "claude"

    func run(target: Watcher.DeepTarget, config: Config, watcher: Watcher) {
        self.target = target
        self.watcher = watcher
        lastConfig = config
        replaced = false
        ask()
    }

    /// `note`: a line to show above the answer while it comes, such as "Connected." after Test connection.
    private func ask(note: String = "") {
        guard let text = target?.text, let config = lastConfig else { return }
        let name = config.deepCheckWith == "auto" ? "your AI" : config.deepCheckName
        revised = nil
        show(mode == .email ? "Asking \(name) to rewrite this as an email\u{2026}" : "Asking \(name)\u{2026}")
        setNote(note)
        let prompt = DeepPrompt.build(config.houseStyle, mode: mode)
        // Only the newest request may fill the window; an older one finishing late is dropped.
        request += 1
        let id = request
        let email = mode == .email
        Task.detached {
            // On Automatic, finding who is signed in starts helper programs, so it happens here, off the main thread.
            var c = config
            c.deepCheckWith = config.resolvedDeepWith()
            let who = Config.name(c.deepCheckWith), company = Config.company(c.deepCheckWith), helper = c.deepCheckWith
            // Say where the text is going before it goes.
            let asking = (email ? "Asking \(who) to rewrite this as an email\u{2026}" : "Asking \(who)\u{2026}")
                + "\n\nDeep check sends this text to \(company), through your \(who) plan. Nothing else Redpen does leaves your Mac."
            await MainActor.run { if id == self.request { self.helper = helper; self.show(asking) } }
            let result = DeepCheck.call(DeepCheck.job(c, prompt: prompt, input: text))
            await MainActor.run { if id == self.request { self.answer(result) } }
        }
    }

    /// Shows a reply. One with revised text can be copied or put back; anything else (not installed, not signed
    /// in, an error) gets the setup buttons instead.
    private func answer(_ reply: String) {
        revised = DeepReplace.revised(from: reply)
        let limit = revised == nil ? DeepCheck.limitMessage(reply, who: Config.name(helper)) : nil
        show(limit.map { $0 + "\n\nDetails:\n" + reply } ?? reply)
        refreshButtons()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .email : .fixOnly
        ask()
    }

    // MARK: Setup

    /// Where to get each helper: the official install page of the company that makes it.
    nonisolated static func setupPage(_ helper: String) -> (title: String, url: URL) {
        switch helper {
        case "chatgpt": ("Get Codex", URL(string: "https://developers.openai.com/codex/cli")!)
        case "gemini": ("Get Antigravity CLI", URL(string: "https://antigravity.google/docs/getting-started?tab=cli")!)
        default: ("Get Claude Code", URL(string: "https://code.claude.com/docs/en/setup")!)
        }
    }

    @objc private func openSetupPage() { NSWorkspace.shared.open(Self.setupPage(helper).url) }

    /// Test connection: is the helper installed, is it signed in, and does it answer a one-word question?
    /// On success, the text is checked straight away.
    @objc private func testConnection() {
        guard var c = lastConfig else { return }
        c.deepCheckWith = helper
        let who = Config.name(helper)
        request += 1
        let id = request
        revised = nil
        show("Testing the connection to \(who)\u{2026}")
        setNote("")
        testButton?.isEnabled = false
        Task.detached {
            let message = DeepCheck.test(c)
            await MainActor.run {
                guard id == self.request else { return }
                self.testButton?.isEnabled = true
                if message.ok, self.target != nil {
                    self.ask(note: "Connected. \(message.text)")
                } else {
                    self.show(message.text)
                    self.refreshButtons()
                }
            }
        }
    }

    /// The three steps of Test connection, each with a plain answer. Runs helper programs, so never on the main thread.
    nonisolated static func test(_ c: Config) -> (ok: Bool, text: String) {
        let job = DeepCheck.job(c, prompt: "Reply with only the word OK.", input: "OK")
        let who = job.name, tool = job.tool
        guard let path = job.path, FileManager.default.isExecutableFile(atPath: path) else {
            try? FileManager.default.removeItem(at: job.folder)
            return (false, "\(tool) isn\u{2019}t installed yet.\n\n" + job.missing)
        }
        let state: HelperRow.State
        switch c.deepCheckWith {
        case "chatgpt": state = Helpers.codex()
        case "gemini": state = Helpers.gemini()
        default: state = Helpers.claude(path: path)
        }
        if case .notSetUp = state {
            try? FileManager.default.removeItem(at: job.folder)
            return (false, "\(tool) is installed but not signed in.\n\n" + signIn(c.deepCheckWith) + "\n\nThen press Test connection again.")
        }
        let started = Date()
        let reply = call(job, limit: 90)
        let seconds = max(1, Int(Date().timeIntervalSince(started).rounded()))
        if reply.count < 40, reply.localizedCaseInsensitiveContains("ok") {
            return (true, "\(who) answered in \(seconds) second\(seconds == 1 ? "" : "s").")
        }
        if let limit = limitMessage(reply, who: who) { return (false, "\(tool) is set up. " + limit) }
        return (false, "\(tool) is installed and signed in, but the test question didn\u{2019}t get a normal answer:\n\n\(reply)")
    }

    /// A plain line when the reply says the writer's plan has hit its usage limit, with the reset time if given.
    nonisolated static func limitMessage(_ reply: String, who: String) -> String? {
        let l = reply.lowercased()
        guard ["quota", "rate limit", "usage limit", "resource_exhausted", "limit reached", "(code 429)"].contains(where: l.contains) else { return nil }
        var s = "Your \(who) plan has reached its limit for now, so Deep check has to wait."
        if let r = reply.range(of: #"[Rr]esets in [0-9hms ]+"#, options: .regularExpression) {
            s += " It " + reply[r].trimmingCharacters(in: .whitespaces).lowercased() + "."
        }
        return s
    }

    /// The sign-in step for each helper, in the words its own screen uses.
    nonisolated static func signIn(_ helper: String) -> String {
        switch helper {
        case "chatgpt": "Open Terminal, type codex and press Return, then choose Sign in with ChatGPT."
        case "gemini": "Open Terminal, type agy and press Return, then sign in with your Google account."
        default: "Open Terminal, type claude and press Return, then sign in with your Claude account."
        }
    }

    /// The message when a helper isn't installed: what it is, the three steps, and the other choices.
    nonisolated static func missing(_ helper: String) -> String {
        let (who, tool, maker) = helper == "chatgpt" ? ("ChatGPT", "Codex", "OpenAI")
            : helper == "gemini" ? ("Gemini", "the Antigravity CLI", "Google") : ("Claude", "Claude Code", "Anthropic")
        let button = setupPage(helper).title
        return "Deep check with \(who) needs \(tool), \(maker)\u{2019}s command-line tool, signed in with your \(who) plan.\n\n"
            + "1. Press \(button) and follow the install steps.\n"
            + "2. \(signIn(helper))\n"
            + "3. Come back here and press Test connection.\n\n"
            + "Would you rather use a different AI? Choose it in Redpen\u{2019}s Settings, under Advanced."
    }

    // MARK: Replace

    /// Replace: brings the writer's app back to the front, then puts the revised text where the checked text was,
    /// only if that text is still there, unchanged.
    @objc private func replaceRevised() {
        guard let target, let revised, let watcher, !replaced else { return }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            setNote("\(target.app) is no longer open. Use Copy revised text."); return
        }
        replaceButton?.isEnabled = false
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            switch watcher.replace(target, with: revised) {
            case .done:
                self.replaced = true
                self.setNote("Replaced in \(target.app). Press \u{2318}Z there to undo.")
            case .refused(let why):
                self.setNote(why)
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
            }
            self.refreshButtons()
        }
    }

    private func refreshButtons() {
        let answered = revised != nil
        copyButton?.isEnabled = answered
        replaceButton?.isEnabled = answered && !replaced && (target?.whole ?? false)
        replaceButton?.toolTip = target?.whole == false ? "This text was too long to send whole. Use Copy revised text."
            : "Puts the revised text in place of the text you checked, only if that text hasn\u{2019}t changed."
        let page = Self.setupPage(helper)
        getButton?.title = page.title
        setupRow?.isHidden = answered
    }

    private func setNote(_ s: String) {
        note?.stringValue = s
        note?.isHidden = s.isEmpty
    }

    /// One run of a helper program: what to start, with which arguments and input, and where its answer lands.
    struct Job: Sendable {
        let name: String
        let tool: String
        let path: String?
        let missing: String
        let args: [String]
        let input: String?
        let answerFile: URL?
        /// An empty folder made for this run alone, deleted afterwards. The helper starts here, so a tool that reads
        /// or writes "the workspace" finds nothing of the writer's.
        let folder: URL
    }

    /// Codex features that let the model act rather than answer: commands, browsers, apps, plugins, images.
    nonisolated static let codexOff = ["shell_tool", "unified_exec", "shell_snapshot", "apps", "browser_use", "browser_use_external",
                                       "in_app_browser", "computer_use", "image_generation", "view_image", "plugins",
                                       "skill_search", "tool_suggest", "sleep_tool"]

    /// Builds the run for the chosen helper. Each starts in its own empty folder.
    ///
    /// Claude Code runs with its tools, MCP servers, skills and hooks switched off, so Claude can only read and
    /// answer the text. Hooks an organisation enforces by managed policy still run; no command line can switch
    /// those off.
    ///
    /// Codex runs read-only, without the user's config, rules, MCP servers, project instructions or web search,
    /// with its command, browser, app and plugin tools switched off, and saves nothing. Its global AGENTS.md still
    /// loads; no flag skips it.
    ///
    /// The Antigravity CLI reads its prompt from the command line, so the text is appended there the way Codex
    /// appends stdin. It runs in Antigravity's sandbox, which restricts terminal commands, with slash commands and
    /// skills off. Headless runs refuse commands that would need approval, and file access is limited to the empty
    /// folder. Commands the user has already allowed in their own Antigravity settings stay allowed, inside the
    /// sandbox; the CLI has no flag to switch those off.
    nonisolated static func job(_ c: Config, prompt: String, input: String) -> Job {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-deep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        switch c.resolvedDeepWith() {
        case "chatgpt":
            let answer = folder.appendingPathComponent("answer.txt")
            return Job(name: "ChatGPT", tool: "Codex", path: c.codexExecutable,
                       missing: missing("chatgpt"),
                       args: ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                              "-s", "read-only", "-C", folder.path, "--color", "never",
                              "-c", "model_reasoning_effort=\"\(c.deepCheckSpeed == "fast" ? "low" : "high")\"",
                              "-c", "project_doc_max_bytes=0", "-c", #"web_search="disabled""#]
                           + codexOff.flatMap { ["--disable", $0] } + ["-o", answer.path, prompt],
                       input: input, answerFile: answer, folder: folder)
        case "gemini":
            return Job(name: "Gemini", tool: "Antigravity CLI", path: c.geminiExecutable,
                       missing: missing("gemini"),
                       args: ["-p", prompt + "\n\n<stdin>\n" + input + "\n</stdin>", "--output-format", "text",
                              "--sandbox", "--disable-slash-commands",
                              "--effort", c.deepCheckSpeed == "fast" ? "low" : "high"],
                       input: nil, answerFile: nil, folder: folder)
        default:
            return Job(name: "Claude", tool: "Claude Code", path: c.claudeExecutable,
                       missing: missing("claude"),
                       args: ["-p", prompt, "--model", c.claudeModel, "--output-format", "text",
                              "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                              "--settings", #"{"disableAllHooks":true}"#],
                       input: input, answerFile: nil, folder: folder)
        }
    }

    /// Runs a job and returns the answer or a plain error. Gives up after `limit` seconds, whatever stalls.
    nonisolated static func call(_ job: Job, limit: TimeInterval = 180) -> String {
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let path = job.path, FileManager.default.isExecutableFile(atPath: path) else { return job.missing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = job.args
        p.currentDirectoryURL = job.folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = job.input == nil ? FileHandle.nullDevice : inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // Output arrives in pieces into locked buffers, so whatever came is readable at any moment, and a helper
        // that keeps a pipe open after the tool exits can't hide a finished reply.
        let out = Collected(), err = Collected()
        out.watch(outPipe.fileHandleForReading)
        err.watch(errPipe.fileHandleForReading)
        do { try p.run() } catch { return "Could not start \(job.tool) at \(path).\n\(error.localizedDescription)" }
        // Writing happens off this thread too: a program that stops reading its input can't stall past the limit.
        if let input = job.input {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        }
        if done.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            return "\(job.name) didn\u{2019}t answer within \(Int(limit / 60)) minutes. Try again, or check a shorter piece."
        }
        out.waitForEnd(seconds: 5)
        err.waitForEnd(seconds: 1)
        // Codex prints its progress to the terminal and saves only the final answer to the file.
        let raw = job.answerFile.flatMap { try? Data(contentsOf: $0) } ?? out.data
        let o = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 || o.isEmpty {
            return "\(job.tool) returned an error (exit \(p.terminationStatus)).\n\n" + String(decoding: err.data, as: UTF8.self)
        }
        return o
    }

    private func show(_ s: String) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Grammar \u{00B7} Deep check"
            w.isReleasedWhenClosed = false
            let picker = NSSegmentedControl(labels: ["Fix only", "Email"], trackingMode: .selectOne,
                                            target: self, action: #selector(modeChanged(_:)))
            picker.selectedSegment = mode == .email ? 1 : 0
            picker.toolTip = "Email rewrites the text as an email: the ask up top, one ask, easy to answer."
            let replace = NSButton(title: "Replace", target: self, action: #selector(replaceRevised))
            replace.bezelStyle = .push
            let copy = NSButton(title: "Copy revised text", target: self, action: #selector(copyRevised))
            copy.bezelStyle = .push
            let bar = NSStackView(views: [picker, NSView(), copy, replace])
            bar.orientation = .horizontal
            bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 6, right: 16)

            let get = NSButton(title: Self.setupPage(helper).title, target: self, action: #selector(openSetupPage))
            get.bezelStyle = .push
            let test = NSButton(title: "Test connection", target: self, action: #selector(testConnection))
            test.bezelStyle = .push
            let setup = NSStackView(views: [get, test, NSView()])
            setup.orientation = .horizontal
            setup.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 6, right: 16)
            setup.isHidden = true

            let n = NSTextField(wrappingLabelWithString: "")
            n.font = .systemFont(ofSize: 13, weight: .medium)
            n.isHidden = true
            let noteRow = NSStackView(views: [n])
            noteRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 6, right: 16)

            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 14)
            tv.textContainerInset = NSSize(width: 16, height: 12)
            let stack = NSStackView(views: [bar, setup, noteRow, scroll])
            stack.orientation = .vertical
            stack.spacing = 0
            stack.alignment = .leading
            for v in [bar, setup, noteRow, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            w.contentView = stack
            window = w
            textView = tv
            modePicker = picker
            replaceButton = replace
            copyButton = copy
            getButton = get
            testButton = test
            setupRow = setup
            note = n
            w.center()
        }
        textView?.string = s
        refreshButtons()
        setupRow?.isHidden = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Test render (`Redpen --render-deep prefix`): the window with an answer, after Replace refused, and with a
    /// helper that isn't installed, saved as PNGs.
    func render(to prefix: String) {
        let sample = "REVISED\nThey're going home now.\n\nCHANGES\n- Their to They're (they are)."
        let states: [(String, String, String, String)] = [
            ("answer", sample, "claude", ""),
            ("refused", sample, "claude", "The text changed while Deep check was running, so Replace stopped to keep your edits. Run Deep check again, or use Copy revised text."),
            ("missing", DeepCheck.missing("chatgpt"), "chatgpt", ""),
        ]
        for (name, reply, who, n) in states {
            helper = who
            replaced = false
            revised = DeepReplace.revised(from: reply)
            show(reply)
            refreshButtons()
            setNote(n)
            window?.appearance = NSAppearance(named: .aqua)
            window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }

    @objc private func copyRevised() {
        guard let s = revised else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }
}

/// Bytes read from a pipe as they arrive, safe to read from any thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let ended = DispatchSemaphore(value: 0)

    var data: Data { lock.withLock { buffer } }

    func watch(_ h: FileHandle) {
        h.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if chunk.isEmpty { h.readabilityHandler = nil; self.ended.signal() } else { self.lock.withLock { self.buffer.append(chunk) } }
        }
    }

    func waitForEnd(seconds: Double) { _ = ended.wait(timeout: .now() + seconds) }
}
