import AppKit
import RedpenCore

/// Sends text to Claude through Claude Code (`claude -p`), so it runs on your Claude subscription, not an API key.
/// The text goes in on stdin, never through a shell.
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
        show(mode == .email ? "Asking Claude to rewrite this as an email\u{2026}" : "Asking Claude\u{2026}")
        let claude = config.claudeExecutable, model = config.deepCheckModel
        let prompt = DeepPrompt.build(config.houseStyle, mode: mode)
        // Only the newest request may fill the window; an older one finishing late is dropped.
        request += 1
        let id = request
        Task.detached {
            let result = DeepCheck.call(claude: claude, model: model, prompt: prompt, input: text)
            await MainActor.run { if id == self.request { self.show(result) } }
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .email : .fixOnly
        ask()
    }

    /// Runs Claude Code with its tools, MCP servers, skills and hooks switched off, so Claude itself can only read
    /// and answer the text. Hooks an organisation enforces by managed policy still run; no command line can switch
    /// those off. Gives up after `limit` seconds, whatever stalls.
    nonisolated static func call(claude: String, model: String, prompt: String, input: String, limit: TimeInterval = 180) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", prompt, "--model", model, "--output-format", "text",
                       "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                       "--settings", #"{"disableAllHooks":true}"#]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // Output arrives in pieces into locked buffers, so whatever came is readable at any moment, and a helper
        // that keeps a pipe open after Claude exits can't hide a finished reply.
        let out = Collected(), err = Collected()
        out.watch(outPipe.fileHandleForReading)
        err.watch(errPipe.fileHandleForReading)
        do { try p.run() } catch { return "Could not start Claude Code at \(claude).\n\(error.localizedDescription)" }
        // Writing happens off this thread too: a program that stops reading its input can't stall past the limit.
        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }
        if done.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            return "Claude didn\u{2019}t answer within \(Int(limit / 60)) minutes. Try again, or check a shorter piece."
        }
        out.waitForEnd(seconds: 5)
        err.waitForEnd(seconds: 1)
        let o = String(decoding: out.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 || o.isEmpty {
            return "Claude Code returned an error (exit \(p.terminationStatus)).\n\n" + String(decoding: err.data, as: UTF8.self)
        }
        return o
    }

    private func show(_ s: String) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen \u{00B7} Deep check"
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
