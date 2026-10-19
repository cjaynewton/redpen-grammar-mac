import AppKit
import ApplicationServices
import RedpenCore

/// First-run window: explains what Redpen needs and waits until macOS grants Accessibility.
@MainActor
final class WelcomeWindow: NSObject {
    private var window: NSWindow?
    private var permissionLine: NSTextField!
    private var engineLine: NSTextField!
    private var timer: Timer?
    var onDone: (() -> Void)?

    func show() {
        if window == nil { build() }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.preferredMaxLayoutWidth = 440
        if secondary { l.textColor = .secondaryLabelColor }
        return l
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Redpen Grammar"
        w.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        stack.addArrangedSubview(label("Redpen checks your writing in any app", size: 18, weight: .semibold))
        stack.addArrangedSubview(label("Spelling mistakes get a red underline, grammar a blue one. Click an underline to fix it and see why. Everything runs on this Mac."))
        stack.addArrangedSubview(label("One permission is needed", size: 14, weight: .semibold))
        stack.addArrangedSubview(label("To read what you type, macOS asks you to allow Redpen under Accessibility once.\n1. Click the button below.\n2. Turn on the switch next to Redpen Grammar. If it is not listed, click + and choose Redpen Grammar in Applications.\n3. Come back here. This window updates by itself."))
        let open = NSButton(title: "Open Accessibility settings", target: self, action: #selector(openSettings))
        open.bezelStyle = .push
        open.keyEquivalent = "\r"
        stack.addArrangedSubview(open)
        permissionLine = label("", weight: .medium)
        stack.addArrangedSubview(permissionLine)
        engineLine = label("", secondary: true)
        stack.addArrangedSubview(engineLine)
        stack.addArrangedSubview(label("Redpen never reads password managers, password fields, or bank and payment pages it can name from the window title. Settings are in the pencil menu at the top of the screen.", size: 12, secondary: true))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .push
        stack.addArrangedSubview(done)

        w.contentView = stack
        w.center()
        window = w
    }

    private func refresh() {
        if AXIsProcessTrusted() {
            permissionLine.stringValue = "\u{2713} Allowed. Redpen is checking your writing."
            permissionLine.textColor = .systemGreen
        } else {
            permissionLine.stringValue = "Waiting for permission\u{2026}"
            permissionLine.textColor = .labelColor
        }
        Task { @MainActor in
            let up = await LanguageTool.isRunning()
            engineLine.stringValue = up
                ? "\u{2713} Grammar engine (LanguageTool) is running."
                : "Spelling and basic grammar work now. For thousands more grammar rules, open the Redpen menu and click Turn on next to Full grammar."
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func finish() {
        timer?.invalidate()
        window?.orderOut(nil)
        onDone?()
    }
}
