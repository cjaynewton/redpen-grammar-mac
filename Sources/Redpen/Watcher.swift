import AppKit
import ApplicationServices
import RedpenCore

/// Watches whatever text field has focus in any app, checks it, and keeps the underlines in place.
@MainActor
final class Watcher {
    var config: Config
    let overlay = Overlay()
    let panel = SuggestionPanel()
    lazy var terminal = TerminalMode(watcher: self)

    private var timer: Timer?
    private var clickMonitor: Any?

    private(set) var element: AXUIElement?
    private var elementPid: pid_t = 0
    private var bundleID = ""
    private var lastText = ""
    private var lastChange = Date.distantPast
    private var lastQuickAt = Date.distantPast
    private var quickIssues: [Issue] = []         // absolute ranges
    private var ltIssues: [Issue] = []            // LanguageTool, absolute ranges
    private var ltKey = ""                        // text slice the LanguageTool result belongs to
    private var ltInFlight = false
    private var modelCache: [String: [Issue]] = [:]  // paragraph text -> issues relative to the paragraph
    private var inFlight: Set<String> = []
    var ignored: Set<String> = []
    private var marks: [Mark] = []
    private let walker = MarkerWalker()
    private var lastLoggedCount = -1
    private var enabledPids: Set<pid_t> = []
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    init(config: Config) { self.config = config }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.click(at: p) }
        }
        terminal.start()
    }

    func clear() {
        element = nil
        ltIssues = []
        ltKey = ""
        lastText = ""
        quickIssues = []
        marks = []
        overlay.hide()
    }

    // MARK: - Loop

    private func tick() {
        guard config.enabled, AXIsProcessTrusted() else {
            Log.note("waiting: enabled=\(config.enabled) trusted=\(AXIsProcessTrusted())"); clear(); terminal.deactivate(); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { clear(); return }
        if app.processIdentifier == ownPid { return }
        let bid = app.bundleIdentifier ?? ""

        if config.terminalApps.contains(bid) { clear(); terminal.activate(app); return }
        terminal.deactivate()
        if config.excludedApps.contains(bid) { clear(); return }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        enableAccessibility(appEl, pid: app.processIdentifier, bundleID: bid)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        var found = AX.element(appEl, kAXFocusedUIElementAttribute)
        if found == nil {  // some apps only answer through the system-wide element
            found = AX.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        }
        guard let el = found else { Log.note("\(bid): no focused element (AX error \(err.rawValue))"); clear(); return }
        let role: String = AX.attr(el, kAXRoleAttribute) ?? ""
        let subrole: String = AX.attr(el, kAXSubroleAttribute) ?? ""
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" { clear(); return }
        if let win = AX.element(appEl, kAXFocusedWindowAttribute), let title: String = AX.attr(win, kAXTitleAttribute),
           config.excludedTitleWords.contains(where: { title.localizedCaseInsensitiveContains($0) }) { clear(); return }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
        guard settable.boolValue || textRoles.contains(role), let text: String = AX.attr(el, kAXValueAttribute) else {
            Log.note("\(bid): focused \(role)/\(subrole) is not readable text"); clear(); return
        }

        if element == nil || !CFEqual(element!, el) {
            clear()
            Log.note("\(bid): reading \(role), \((text as NSString).length) chars")
            element = el
            elementPid = app.processIdentifier
            bundleID = bid
        }

        let now = Date()
        if text != lastText {
            lastText = text
            lastChange = now
        }
        // Spelling and rules: as soon as typing slows, without waiting for a full pause.
        if lastQuickAt < lastChange && now.timeIntervalSince(lastChange) > 0.3 {
            lastQuickAt = now
            runQuick(el, text)
        }
        // Apple's model: after a real pause, on the paragraph at the cursor.
        // LanguageTool: fast local rules, after a short pause.
        if now.timeIntervalSince(lastChange) > 0.5 { runLanguageTool(el, text) }
        if now.timeIntervalSince(lastChange) > 1.0 { runModel(el, text) }

        redraw(el, text)
    }

    private var isLongform: Bool { config.longformApps.contains(bundleID) || (lastText as NSString).length > 600 }

    /// The slice of text worth checking: what is on screen, or a window around the cursor in huge documents.
    private func window(_ el: AXUIElement, _ text: String) -> NSRange {
        let len = (text as NSString).length
        if let vis = AX.range(el, "AXVisibleCharacterRange"), vis.length > 0, NSMaxRange(vis) <= len { return vis }
        if len <= 20000 { return NSRange(location: 0, length: len) }
        let cur = AX.range(el, kAXSelectedTextRangeAttribute)?.location ?? 0
        let start = max(0, cur - 10000)
        return NSRange(location: start, length: min(20000, len - start))
    }

    private func runQuick(_ el: AXUIElement, _ text: String) {
        let w = window(el, text)
        let ns = text as NSString
        // Snap to paragraph edges so sentences are whole.
        let pr = ns.paragraphRange(for: w)
        quickIssues = Engine.quick(ns.substring(with: pr), longform: isLongform, style: config.houseStyle).map {
            var i = $0; i.range = i.range.shifted(by: pr.location); return i
        }
    }

    private func runLanguageTool(_ el: AXUIElement, _ text: String) {
        let ns = text as NSString
        let pr = ns.paragraphRange(for: window(el, text))
        let slice = ns.substring(with: pr)
        let key = "\(pr.location)|\(slice)"
        guard key != ltKey, !ltInFlight else { return }
        ltInFlight = true
        Task { @MainActor in
            let found = await LanguageTool.check(slice).map { var i = $0; i.range = i.range.shifted(by: pr.location); return i }
            self.ltIssues = found
            self.ltKey = key
            self.ltInFlight = false
        }
    }

    /// One paragraph at a time: the one at the cursor first, then the rest of what is on screen.
    private func runModel(_ el: AXUIElement, _ text: String) {
        guard inFlight.isEmpty else { return }
        let ns = text as NSString
        let cur = AX.range(el, kAXSelectedTextRangeAttribute)?.location ?? 0
        var candidates = [Engine.paragraph(in: text, at: cur).0]
        ns.enumerateSubstrings(in: ns.paragraphRange(for: window(el, text)), options: [.byParagraphs, .substringNotRequired]) { _, _, enc, _ in
            candidates.append(ns.substring(with: enc))
        }
        guard let para = candidates.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && modelCache[$0] == nil
        }) else { return }
        if modelCache.count > 400 { modelCache.removeAll() }
        inFlight.insert(para)
        Task { @MainActor in
            let found = await Engine.deep(para)
            self.modelCache[para] = found
            self.inFlight.remove(para)
        }
    }

    /// All current issues with absolute ranges, minus ignored ones and the word still being typed.
    private func currentIssues(_ el: AXUIElement, _ text: String) -> [Issue] {
        let ns = text as NSString
        var model: [Issue] = []
        let w = ns.paragraphRange(for: window(el, text))
        ns.enumerateSubstrings(in: w, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let para = ns.substring(with: enclosing)
            if let found = self.modelCache[para] {
                model += found.map { var i = $0; i.range = i.range.shifted(by: enclosing.location); return i }
            }
        }
        let spelling = Engine.spellingAgreed(quickIssues, lt: ltIssues)
        var all = Engine.merge(spelling, ltIssues.filter { $0.kind != .spelling })
        all = Engine.merge(all, model)
        // Drop anything that no longer matches the text (it was edited since the check).
        all = all.filter { NSMaxRange($0.range) <= ns.length && ns.substring(with: $0.range) == $0.original }
        all = all.filter { !ignored.contains($0.ignoreKey) }
        if Date().timeIntervalSince(lastChange) < 1.5, let cur = AX.range(el, kAXSelectedTextRangeAttribute) {
            all = all.filter { !(NSMaxRange($0.range) == cur.location && $0.kind == .spelling) }
        }
        return all
    }

    private func redraw(_ el: AXUIElement, _ text: String) {
        let issues = currentIssues(el, text)
        guard !issues.isEmpty else { marks = []; overlay.hide(); return }
        var out: [Mark] = []
        for i in issues.prefix(80) {
            for r in lineRects(el, i.range) { out.append(Mark(issue: i, rect: AX.toCocoa(r))) }
        }
        marks = out
        if out.isEmpty, let i = issues.first {
            var cf = CFRange(location: i.range.location, length: i.range.length)
            var raw: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                 AXValueCreate(.cfRange, &cf)!, &raw)
            Log.note("\(bundleID): no position for \(i.range) err=\(err.rawValue) raw=\(raw.map { "\($0)" } ?? "nil")")
        }
        if issues.count != lastLoggedCount {
            lastLoggedCount = issues.count
            Log.note("\(bundleID): \(issues.count) issues, \(out.count) underlines placed")
        }
        let frame = AX.frame(el).map { AX.toCocoa($0) } ?? out.reduce(CGRect.null) { $0.union($1.rect) }
        overlay.show(out, over: frame.insetBy(dx: -4, dy: -6))
    }

    /// Bounds of a range split by line, so an error that wraps gets an underline on each line.
    private func lineRects(_ el: AXUIElement, _ r: NSRange) -> [CGRect] {
        guard let whole = AX.bounds(el, for: r) else {
            return walker.bounds(el, text: lastText, range: r).map { [$0] } ?? []
        }
        guard r.length > 1, let first = AX.bounds(el, for: NSRange(location: r.location, length: 1)),
              whole.height > first.height * 1.6 else { return [whole] }
        guard let last = AX.bounds(el, for: NSRange(location: NSMaxRange(r) - 1, length: 1)) else { return [first] }
        return [CGRect(x: first.minX, y: first.minY, width: whole.maxX - first.minX, height: first.height),
                CGRect(x: whole.minX, y: last.minY, width: last.maxX - whole.minX, height: last.height)]
    }

    // MARK: - Click to fix

    private func click(at p: CGPoint) {
        guard !panel.isVisible else { return }
        guard let m = marks.first(where: { $0.rect.insetBy(dx: -1, dy: -4).contains(p) }), let el = element else { return }
        open(m.issue, in: el, anchor: m.rect)
    }

    private func open(_ issue: Issue, in el: AXUIElement, anchor: CGRect) {
        if issue.message.hasPrefix("This came through in") && issue.replacements.isEmpty {
            Task { @MainActor in
                var i = issue
                if let t = await AppleModel.translate(issue.original) { i.replacements = [t] }
                self.showPanel(i, el, anchor)
            }
            return
        }
        showPanel(issue, el, anchor)
    }

    private func showPanel(_ issue: Issue, _ el: AXUIElement, _ anchor: CGRect) {
        var choices: [SuggestionPanel.Choice] = issue.replacements.prefix(3).map { rep in
            let shown = rep.isEmpty ? "Delete \u{201C}\(issue.original)\u{201D}" : rep.trimmingCharacters(in: .whitespaces)
            return .init(title: shown.isEmpty ? "Replace" : shown, primary: true) { [weak self] in
                self?.apply(issue, rep, in: el)
            }
        }
        if issue.kind == .spelling {
            choices.append(.init(title: "Add \u{201C}\(issue.original)\u{201D} to dictionary", primary: false) { [weak self] in
                Spelling.learn(issue.original); self?.lastQuickAt = .distantPast
            })
        }
        choices.append(.init(title: "Ignore", primary: false) { [weak self] in self?.ignored.insert(issue.ignoreKey) })
        panel.show(title: issue.kind.label, color: issue.kind.color, message: issue.message, detail: lessonText(issue),
                   choices: choices, below: anchor)
    }

    /// The teaching line under the fix: the rule, an example, and how often this one has come up lately.
    func lessonText(_ issue: Issue) -> String? {
        guard let l = Lessons.lesson(for: issue) else { return nil }
        var parts = ["Why: \(l.rule)"]
        if !l.example.isEmpty { parts.append("Example: \(l.example)") }
        let n = Mistakes.shared.count(l.id)
        if n >= 2 { parts.append("You've fixed this one \(n) times in the last 30 days.") }
        return parts.joined(separator: "\n")
    }

    /// Replaces the text through Accessibility; falls back to select-and-paste for apps that refuse.
    func apply(_ issue: Issue, _ replacement: String, in el: AXUIElement) {
        guard let text: String = AX.attr(el, kAXValueAttribute) else { NSSound.beep(); return }
        let ns = text as NSString
        guard NSMaxRange(issue.range) <= ns.length, ns.substring(with: issue.range) == issue.original else { NSSound.beep(); return }
        guard AX.setRange(el, issue.range) else { NSSound.beep(); return }
        Mistakes.shared.record(issue, replacement: replacement, app: bundleID)
        let expected = ns.replacingCharacters(in: issue.range, with: replacement)
        if AX.set(el, kAXSelectedTextAttribute, replacement as CFString),
           let after: String = AX.attr(el, kAXValueAttribute), after == expected {
            lastText = ""
            return
        }
        // Some apps (Electron, Office) ignore direct writes. Paste over the selection instead.
        Paste.replaceSelection(with: replacement)
        lastText = ""
    }

    // MARK: - App quirks

    /// Chromium browsers and Electron apps hide their text from Accessibility until asked.
    private func enableAccessibility(_ appEl: AXUIElement, pid: pid_t, bundleID: String) {
        guard !enabledPids.contains(pid) else { return }
        enabledPids.insert(pid)
        AX.set(appEl, "AXManualAccessibility", kCFBooleanTrue)          // Electron (Slack, Notion, VS Code...)
        if config.chromiumApps.contains(bundleID) || config.officeApps.contains(bundleID) {
            AX.set(appEl, "AXEnhancedUserInterface", kCFBooleanTrue)  // Chrome, Brave, Edge, Arc, Office
        }
    }

    /// Text in the focused field for the deep check: the selection if there is one, else the whole field.
    func textForDeepCheck() -> String? {
        guard let el = element else { return nil }
        if let sel: String = AX.attr(el, kAXSelectedTextAttribute), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sel
        }
        let t: String? = AX.attr(el, kAXValueAttribute)
        return t.map { String($0.prefix(20000)) }
    }
}

/// Puts text on the clipboard, presses Cmd+V, then restores what was there.
enum Paste {
    static let marker: Int64 = 0x5245_4450  // "REDP": lets Redpen ignore its own keystrokes

    static func replaceSelection(with s: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(s, forType: .string)
        key(9, flags: .maskCommand)  // V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func type(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }
}
