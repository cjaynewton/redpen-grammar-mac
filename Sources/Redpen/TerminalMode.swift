import AppKit
import RedpenCore

/// Terminals show the whole screen as one block of text, so there is no input box to underline.
/// Instead Redpen follows the keys typed on the current line and offers fixes in a small bubble.
@MainActor
final class TerminalMode {
    unowned let watcher: Watcher
    private var keyMonitor: Any?
    private var active = false
    private var app: NSRunningApplication?
    private var buffer = ""          // what has been typed on the current line, cursor assumed at the end
    private var lastKey = Date.distantPast
    private var checkedBuffer = ""
    private var shownKeys: [String] = []
    private var owner: AXUIElement?  // the pane the buffer was typed into
    private var mouseMonitor: Any?

    init(watcher: Watcher) { self.watcher = watcher }

    func start() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mine = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == Paste.marker
            let chars = e.characters ?? ""
            let code = e.keyCode
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { if !mine { self?.key(code: code, chars: chars, flags: flags) } }
        }
        // A click can move the cursor or switch panes, and Redpen can't see where it lands, so start over.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active == true { self?.reset() } }
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func activate(_ app: NSRunningApplication) {
        if self.app?.processIdentifier != app.processIdentifier { reset() }
        self.app = app
        active = true
    }

    func deactivate() {
        guard active else { return }
        active = false
        reset()
    }

    private func reset() {
        buffer = ""
        checkedBuffer = ""
        shownKeys = []
        owner = nil
        watcher.panel.hide()
    }

    private func key(code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
        guard active else { return }
        lastKey = Date()
        switch code {
        case 36, 76: reset(); return                     // Return: line sent
        case 51:  // Delete. With Option, Command or Control it removes a word or the line; Redpen can't know how much.
            if !flags.intersection([.option, .command, .control]).isEmpty { reset(); return }
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 53, 48, 115, 116, 117, 119, 121, 123, 124, 125, 126:  // Esc, Tab, Home, PgUp, Fwd-Del, End, PgDn, arrows
            reset(); return
        default: break
        }
        if flags.contains(.command) {
            if code == 9, let s = NSPasteboard.general.string(forType: .string), !s.contains("\n") { buffer += s }  // Cmd+V
            else { reset() }
            return
        }
        if flags.contains(.control) || flags.contains(.option) && chars.isEmpty { reset(); return }
        if let c = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c) {
            if buffer.isEmpty { owner = focusedElement() }
            buffer += chars
        }
    }

    private func focusedElement() -> AXUIElement? {
        guard let app else { return nil }
        return AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
    }

    /// True when the same terminal and the same pane still have focus as when the buffer was typed.
    private func stillSamePane() -> Bool {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        guard let owner, let now = focusedElement() else { return owner == nil }
        return CFEqual(owner, now)
    }

    /// Only prose gets checked: shell commands are full of words no dictionary knows.
    private func looksLikeProse(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard words.count >= 4 else { return false }
        if let f = s.first, "$./~-|>".contains(f) { return false }
        let plain = words.filter { $0.allSatisfy { $0.isLetter || "',.?!:;\u{2019}".contains($0) } }
        return Double(plain.count) / Double(words.count) >= 0.75
    }

    private func tick() {
        guard active, !buffer.isEmpty, Date().timeIntervalSince(lastKey) > 0.9, buffer != checkedBuffer else { return }
        checkedBuffer = buffer
        guard looksLikeProse(buffer) else { return }
        let snapshot = buffer
        Task { @MainActor in
            let issues = await Engine.full(snapshot, longform: false, style: self.watcher.config.houseStyle)
                .filter { !self.watcher.ignored.contains($0.ignoreKey) && !$0.replacements.isEmpty }
            guard self.active, self.buffer == snapshot, self.stillSamePane() else { return }
            self.show(issues, for: snapshot)
        }
    }

    private func show(_ issues: [Issue], for text: String) {
        let keys = issues.map(\.ignoreKey)
        guard !issues.isEmpty else { watcher.panel.hide(); shownKeys = []; return }
        if keys == shownKeys && watcher.panel.isVisible { return }
        shownKeys = keys

        var seen = Set<String>()
        let lessons = issues.compactMap { Lessons.lesson(for: $0) }
            .filter { !$0.rule.hasPrefix("Spelled ") && seen.insert($0.id).inserted }
        var card = SuggestionPanel.Card(kind: "Terminal", color: issues[0].color,
                                        marks: issues.prefix(4).map { ($0.original, $0.replacements[0]) },
                                        message: nil, why: lessons.first?.rule, example: lessons.first?.example)
        card.primary = .init(title: issues.count == 1 ? "Fix it" : "Fix all \(issues.count)") { [weak self] in
            self?.fix(issues, in: text)
        }
        card.footer = [.init(title: "Ignore") { [weak self] in
            for k in keys { self?.watcher.ignored.insert(k) }
        }]
        watcher.panel.show(card, below: anchor())
    }

    /// Near the bottom-left of the terminal window, where the prompt usually is.
    private func anchor() -> CGRect {
        if let app {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            if let win = AX.element(appEl, kAXFocusedWindowAttribute), let f = AX.frame(win) {
                let c = AX.toCocoa(f)
                return CGRect(x: c.minX + 24, y: c.minY + 150, width: 10, height: 10)
            }
        }
        let m = NSEvent.mouseLocation
        return CGRect(x: m.x, y: m.y, width: 10, height: 10)
    }

    /// Deletes back to the first change and retypes the corrected tail. Safe because the cursor is at the end of
    /// the buffer: any key that could move it resets the buffer.
    private func fix(_ issues: [Issue], in text: String) {
        guard buffer == text, stillSamePane() else { NSSound.beep(); reset(); return }
        var fixed = text as NSString
        for i in issues.sorted(by: { $0.range.location > $1.range.location }) {
            fixed = fixed.replacingCharacters(in: i.range, with: i.replacements[0]) as NSString
        }
        let new = fixed as String
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "terminal"
        for i in issues { Mistakes.shared.record(i, replacement: i.replacements[0], app: app) }
        let common = text.commonPrefix(with: new)
        let deletions = text.count - common.count
        for _ in 0..<deletions { Paste.key(51) }
        Paste.type(String(new.dropFirst(common.count)))
        buffer = new
        checkedBuffer = new
    }
}
