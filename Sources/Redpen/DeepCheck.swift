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

    func run(text: String, config: Config) {
        lastText = text
        lastConfig = config
        ask()
    }

    private func ask() {
        guard let text = lastText, let config = lastConfig else { return }
        show(mode == .email ? "Asking Claude to rewrite this as an email\u{2026}" : "Asking Claude\u{2026}")
        let claude = config.claudePath, model = config.deepCheckModel
        let prompt = DeepPrompt.build(config.houseStyle, mode: mode)
        Task.detached {
            let result = DeepCheck.call(claude: claude, model: model, prompt: prompt, input: text)
            await MainActor.run { self.show(result) }
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .email : .fixOnly
        ask()
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
