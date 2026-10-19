import AppKit
import RedpenCore

/// Sends text to Claude, ChatGPT or Gemini through each one's official command-line tool (Claude Code, Codex,
/// Antigravity CLI), so it runs on the writer's own plan, not an API key. Arguments go straight to the program,
/// never through a shell.
@MainActor
final class DeepCheck {
    private var window: NSWindow?
    private var textView: NSTextView?

    private var lastText: String?
    private var lastConfig: Config?
    private var mode: DeepMode = .fixOnly
    private var modePicker: NSSegmentedControl?
    private var request = 0

    func run(text: String, config: Config) {
        lastText = text
        lastConfig = config
        ask()
    }

    private func ask() {
        guard let text = lastText, let config = lastConfig else { return }
        let name = config.deepCheckWith == "auto" ? "your AI" : config.deepCheckName
        show(mode == .email ? "Asking \(name) to rewrite this as an email\u{2026}" : "Asking \(name)\u{2026}")
        let prompt = DeepPrompt.build(config.houseStyle, mode: mode)
        // Only the newest request may fill the window; an older one finishing late is dropped.
        request += 1
        let id = request
        let email = mode == .email
        Task.detached {
            // On Automatic, finding who is signed in starts helper programs, so it happens here, off the main thread.
            var c = config
            c.deepCheckWith = config.resolvedDeepWith()
            let who = Config.name(c.deepCheckWith), company = Config.company(c.deepCheckWith)
            // Say where the text is going before it goes.
            let asking = (email ? "Asking \(who) to rewrite this as an email\u{2026}" : "Asking \(who)\u{2026}")
                + "\n\nDeep check sends this text to \(company), through your \(who) plan. Nothing else Redpen does leaves your Mac."
            await MainActor.run { if id == self.request { self.show(asking) } }
            let result = DeepCheck.call(DeepCheck.job(c, prompt: prompt, input: text))
            await MainActor.run { if id == self.request { self.show(result) } }
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .email : .fixOnly
        ask()
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
                       missing: "Deep check with ChatGPT needs Codex. Install it, then sign in with your ChatGPT account.",
                       args: ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                              "-s", "read-only", "-C", folder.path, "--color", "never",
                              "-c", "model_reasoning_effort=\"\(c.deepCheckSpeed == "fast" ? "low" : "high")\"",
                              "-c", "project_doc_max_bytes=0", "-c", #"web_search="disabled""#]
                           + codexOff.flatMap { ["--disable", $0] } + ["-o", answer.path, prompt],
                       input: input, answerFile: answer, folder: folder)
        case "gemini":
            return Job(name: "Gemini", tool: "Antigravity CLI", path: c.geminiExecutable,
                       missing: "Deep check with Gemini needs Google\u{2019}s Antigravity CLI. Install it, run agy once and sign in with your Google account.",
                       args: ["-p", prompt + "\n\n<stdin>\n" + input + "\n</stdin>", "--output-format", "text",
                              "--sandbox", "--disable-slash-commands",
                              "--effort", c.deepCheckSpeed == "fast" ? "low" : "high"],
                       input: nil, answerFile: nil, folder: folder)
        default:
            return Job(name: "Claude", tool: "Claude Code", path: c.claudeExecutable,
                       missing: "Deep check with Claude needs Claude Code. Install it, then sign in with your Claude account.",
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Grammar \u{00B7} Deep check"
            w.isReleasedWhenClosed = false
            let picker = NSSegmentedControl(labels: ["Fix only", "Email"], trackingMode: .selectOne,
                                            target: self, action: #selector(modeChanged(_:)))
            picker.selectedSegment = mode == .email ? 1 : 0
            picker.toolTip = "Email rewrites the text as an email: the ask up top, one ask, easy to answer."
            let copy = NSButton(title: "Copy revised text", target: self, action: #selector(copyRevised))
            copy.bezelStyle = .push
            let bar = NSStackView(views: [picker, NSView(), copy])
            bar.orientation = .horizontal
            bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 14)
            tv.textContainerInset = NSSize(width: 16, height: 12)
            let stack = NSStackView(views: [bar, scroll])
            stack.orientation = .vertical
            stack.spacing = 0
            stack.alignment = .leading
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            w.contentView = stack
            window = w
            textView = tv
            modePicker = picker
            w.center()
        }
        textView?.string = s
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyRevised() {
        let s = textView?.string ?? ""
        var revised = s
        if let r = s.range(of: "REVISED") {
            revised = String(s[r.upperBound...])
            if let c = revised.range(of: "\nCHANGES") { revised = String(revised[..<c.lowerBound]) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(revised.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
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
