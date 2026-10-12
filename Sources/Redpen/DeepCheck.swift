import AppKit
import RedpenCore

/// Sends text to Claude through Claude Code (`claude -p`), so it runs on your Claude subscription, not an API key.
/// The text goes in on stdin, never through a shell.
@MainActor
final class DeepCheck {
    private var window: NSWindow?
    private var textView: NSTextView?

    /// The writer's house style, turned into plain instructions for Claude.
    nonisolated static func prompt(_ style: HouseStyle) -> String {
        var rules: [String] = []
        if style.noDashes { rules.append("no em dashes; use a period or comma") }
        if style.colonsOnlyForLabels { rules.append("colons only for labels and lists; a colon joining two thoughts becomes a period") }
        if !style.containerWords.isEmpty { rules.append("avoid vague words like " + style.containerWords.prefix(6).joined(separator: ", ")) }
        if !style.disclaimers.isEmpty { rules.append("cut defensive disclaimers") }
        if style.flagOtherLanguages { rules.append("the result must be in English") }
        var p = "Edit the text on stdin. Fix grammar and spelling. Keep the writer's meaning and voice; do not add ideas."
        if !rules.isEmpty { p += " Also apply the writer's house style: " + rules.joined(separator: "; ") + "." }
        let notes = style.deepCheckNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { p += " Writer's notes: " + notes }
        return p + "\n" + format
    }

    nonisolated static let format = """
    Reply in exactly this form, plain text, no markdown headings:
    REVISED
    <the full revised text>

    CHANGES
    - <one short line per change, most important first>
    """

    func run(text: String, config: Config) {
        show("Asking Claude\u{2026}")
        let claude = config.claudePath
        let model = config.deepCheckModel
        let style = config.houseStyle
        Task.detached {
            let result = DeepCheck.call(claude: claude, model: model, prompt: DeepCheck.prompt(style), input: text)
            await MainActor.run { self.show(result) }
        }
    }

    nonisolated static func call(claude: String, model: String, prompt: String, input: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", prompt, "--model", model, "--output-format", "text"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return "Could not start Claude Code at \(claude).\n\(error.localizedDescription)" }
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let o = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 || o.isEmpty {
            return "Claude Code returned an error (exit \(p.terminationStatus)).\n\n" + String(decoding: err, as: UTF8.self)
        }
        return o
    }

    private func show(_ s: String) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen \u{00B7} Deep check"
            w.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 14)
            tv.textContainerInset = NSSize(width: 16, height: 16)
            w.contentView = scroll
            let copy = NSButton(title: "Copy revised text", target: self, action: #selector(copyRevised))
            copy.bezelStyle = .push
            w.standardWindowButton(.closeButton)?.superview?.addSubview(copy)
            copy.frame = NSRect(x: 460, y: 0, width: 150, height: 26)
            copy.autoresizingMask = [.minXMargin]
            window = w
            textView = tv
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
