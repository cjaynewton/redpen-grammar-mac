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
    private var watchdog: DispatchSourceTimer?
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
    private var cardMark: Mark?                   // the underline whose card is open, to close it if the text moves
    private var lostSince: Date?
    private var lastContainer: AXUIElement?       // Word's focused page, and the text area found inside it
    private var lastInner: AXUIElement?                 // when the focused field last stopped answering
    private let walker = MarkerWalker()
    private var lastLoggedCount = -1
    private var enabledPids: Set<pid_t> = []
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private var lastBeat = Date.distantPast
    private var beats = 0

    init(config: Config) { self.config = config }

    func start() {
        // An app that is slow to answer Accessibility would otherwise hold every check for up to 6 s (the
        // system default). Setting it on the system-wide element sets it for every element Redpen asks.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        startLoop()
        startWatchdog()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.click(at: p) }
        }
        terminal.start()
    }

    /// The check loop runs in the common run-loop modes, so it keeps going while a menu or a button
    /// is tracking the mouse instead of waiting for the default mode to come back.
    private func startLoop() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let started = Date()
                self?.tick()
                let took = Date().timeIntervalSince(started)
                if took > 0.5, let self { Log.note("slow check: \(Int(took * 1000)) ms in \(self.bundleID)") }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    nonisolated(unsafe) private static var lastTick = Date()

    /// The check loop twice went silent with the app otherwise idle (Oct 14 2026). A background clock notices,
    /// logs what the main run loop is doing, and restarts the loop.
    private func startWatchdog() {
        let s = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "redpen.watchdog"))
        s.schedule(deadline: .now() + 10, repeating: 10)
        s.setEventHandler { [weak self] in
            let stale = Date().timeIntervalSince(Watcher.lastTick)
            guard stale > 5 else { return }
            let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "none"
            Log.note("watchdog: no check for \(Int(stale)) s, main run loop mode \(mode)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.note("watchdog: main thread answered, restarting the check loop")
                    self?.startLoop()
                }
            }
        }
        s.resume()
        watchdog = s
    }

    func clear() {
        element = nil
        ltIssues = []
        ltKey = ""
        lastText = ""
        quickIssues = []
        marks = []
        lostSince = nil
        overlay.hide()
    }

    /// The text area inside a container: the focused one if any, else the one holding the most text.
    private func textInside(_ root: AXUIElement) -> AXUIElement? {
        var best: (AXUIElement, Int)?
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 10, visited < 600 else { return nil }
            visited += 1
            let role: String = AX.attr(e, kAXRoleAttribute) ?? ""
            if role == "AXTextArea", let v: String = AX.attr(e, kAXValueAttribute) {
                if let f: Bool = AX.attr(e, kAXFocusedAttribute), f { return e }
                if v.count > (best?.1 ?? -1) { best = (e, v.count) }
                return nil
            }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { if let hit = walk(c, depth + 1) { return hit } }
            return nil
        }
        if let hit = walk(root, 0) { return hit }
        if best != nil { Log.note("\(bundleID): using the document text inside the focused container") }
        return best?.0
    }

    /// Chrome reports nothing in focus for a moment when a word is clicked. Keep the underlines through a
    /// short blip in the same app, so the click still lands on them; clear only if it lasts.
    private func lost(_ pid: pid_t) {
        if element != nil, elementPid == pid {
            let now = Date()
            if lostSince == nil { lostSince = now }
            if now.timeIntervalSince(lostSince!) < 1.5 { return }
        }
        clear()
    }

    // MARK: - Loop

    private func tick() {
        Watcher.lastTick = Date()
        if Date().timeIntervalSince(lastBeat) > 60 {
            lastBeat = Date(); beats += 1
            Log.note("alive \(beats): front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), field \(element == nil ? "none" : "held"), \(marks.count) underlines, card \(panel.isVisible ? "open" : "closed")")
        }
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
        // Word sometimes reports the page around the document (a split group or scroll area) as focused,
        // not the text. Look inside it for the document's text area.
        if let f = found, config.officeApps.contains(bid),
           ["AXSplitGroup", "AXScrollArea", "AXGroup", "AXLayoutArea", "AXApplication", "AXWindow"].contains(AX.attr(f, kAXRoleAttribute) ?? ""),
           let inner = (lastContainer.map { CFEqual($0, f) } == true ? lastInner : nil) ?? textInside(f) {
            lastContainer = f; lastInner = inner  // walking Word's tree every tick would be slow
            found = inner
        }
        guard let el = found else { Log.note("\(bid): no focused element (AX error \(err.rawValue))"); lost(app.processIdentifier); return }
        let role: String = AX.attr(el, kAXRoleAttribute) ?? ""
        let subrole: String = AX.attr(el, kAXSubroleAttribute) ?? ""
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" { clear(); return }
        if let win = AX.element(appEl, kAXFocusedWindowAttribute), let title: String = AX.attr(win, kAXTitleAttribute),
           config.excludedTitleWords.contains(where: { title.localizedCaseInsensitiveContains($0) }) { clear(); return }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
        guard settable.boolValue || textRoles.contains(role), let text: String = AX.attr(el, kAXValueAttribute) else {
            Log.note("\(bid): focused \(role)/\(subrole) is not readable text"); lost(app.processIdentifier); return
        }
        lostSince = nil

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
        var all = Engine.merge(spelling, Engine.protectNames(ltIssues.filter { $0.kind != .spelling }, in: text))
        all = Engine.merge(all, Engine.protectNames(model, in: text))
        all = Engine.outsideQuotes(all, in: text)
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
        guard !issues.isEmpty else { marks = []; overlay.hide(); closeCardIfMoved(); return }
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
        closeCardIfMoved()
    }

    /// A card left behind when its word scrolls away, or after the word is edited, points at nothing.
    private func closeCardIfMoved() {
        guard panel.isVisible, let open = cardMark else { return }
        let now = marks.first(where: { $0.issue == open.issue })?.rect
        if now == nil || abs(now!.minX - open.rect.minX) > 3 || abs(now!.minY - open.rect.minY) > 3 {
            Log.note("card closed: \u{201C}\(open.issue.original)\u{201D} \(now == nil ? "is gone" : "moved")")
            panel.hide()
            cardMark = nil
        }
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

    /// Control-Option-R: open the card for the mistake at or nearest the cursor, without aiming at an underline.
    /// Works even where the app gives no word positions; the card then opens under the text field.
    func openNearest() {
        Log.note("shortcut pressed in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        if panel.isVisible { panel.hide(); return }
        guard let el = element, !lastText.isEmpty else { Log.note("shortcut: no text field in focus"); NSSound.beep(); return }
        let issues = currentIssues(el, lastText)
        guard !issues.isEmpty else { Log.note("shortcut: no mistakes in \(bundleID)"); NSSound.beep(); return }
        let cur = AX.range(el, kAXSelectedTextRangeAttribute)?.location ?? 0
        func distance(_ i: Issue) -> Int {
            cur < i.range.location ? i.range.location - cur : cur > NSMaxRange(i.range) ? cur - NSMaxRange(i.range) : 0
        }
        let issue = issues.min { distance($0) < distance($1) }!
        let anchor = marks.first(where: { $0.issue == issue })?.rect
            ?? lineRects(el, issue.range).first.map(AX.toCocoa)
            ?? AX.frame(el).map { f in let c = AX.toCocoa(f); return CGRect(x: c.minX + 8, y: c.minY, width: 1, height: 1) }
        guard let anchor else { Log.note("shortcut: no place to open the card"); NSSound.beep(); return }
        Log.note("shortcut: opened \u{201C}\(issue.original)\u{201D} in \(bundleID)\(marks.contains { $0.issue == issue } ? "" : " (under the field)")")
        cardMark = marks.first(where: { $0.issue == issue })
        open(issue, in: el, anchor: anchor)
    }

    /// The click itself still reaches the app, so the caret lands in the word and the app's own selection
    /// and toolbars behave as usual. Redpen only decides whether its card opens, stays, switches or closes.
    private func click(at p: CGPoint) {
        // Hit-test against fresh positions: the underlines are redrawn four times a second, and a click
        // just after scrolling or typing would otherwise land on where a word used to be.
        if let el = element, !lastText.isEmpty { redraw(el, lastText) }
        let hit = marks.first(where: { $0.rect.insetBy(dx: -1, dy: -4).contains(p) })
        let action = CardPlacement.onClick(cardOpen: panel.isVisible, hit: hit != nil, hitSame: hit != nil && hit?.issue == cardMark?.issue)
        if element != nil || !marks.isEmpty {
            let near = marks.prefix(3).map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }
            Log.note("click at \(Int(p.x)),\(Int(p.y)) in \(bundleID): \(marks.count) underlines, \(hit == nil ? "none hit" : "hit \u{201C}\(hit!.issue.original)\u{201D}"), field \(element == nil ? "gone" : "held"), card \(action) [\(near.joined(separator: "; "))]")
        }
        switch action {
        case .ignore, .keep: return
        case .close: panel.hide(); cardMark = nil
        case .open:
            guard let m = hit, let el = element else { return }
            cardMark = m
            open(m.issue, in: el, anchor: m.rect)
        }
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
        let reps = issue.replacements.prefix(3).map { $0 }
        func shown(_ rep: String) -> String {
            let t = rep.trimmingCharacters(in: .whitespaces)
            return rep.isEmpty ? "Cut it" : t.isEmpty ? "Replace" : t
        }
        func use(_ rep: String) -> SuggestionPanel.Choice {
            .init(title: rep.isEmpty ? "Cut it" : "Use \u{201C}\(shown(rep))\u{201D}") { [weak self] in self?.apply(issue, rep, in: el) }
        }
        var footer: [SuggestionPanel.Choice] = []
        if issue.kind == .spelling {
            footer.append(.init(title: "Add to dictionary") { [weak self] in
                Spelling.learn(issue.original); self?.lastQuickAt = .distantPast
            })
        }
        footer.append(.init(title: "Ignore") { [weak self] in self?.ignored.insert(issue.ignoreKey) })
        let lesson = Lessons.lesson(for: issue)
        // "Spelled \u{201C}test\u{201D}." teaches nothing: show a spelling lesson only when it has a real memory trick.
        let teaches = lesson.map { !($0.rule.hasPrefix("Spelled ")) } ?? false
        var card = SuggestionPanel.Card(kind: issue.label, color: issue.color,
                                        marks: [(issue.original, reps.first.map(shown))],
                                        message: Self.cardMessage(issue),
                                        // The specific message beats the general rule; show the rule only when there is no message.
                                        why: teaches && Self.cardMessage(issue) == nil ? lesson?.rule : nil,
                                        example: teaches ? lesson?.example : nil,
                                        count: lesson.map { Mistakes.shared.count($0.id) } ?? 0)
        if let first = reps.first {
            card.primary = use(first)
            card.alts = reps.dropFirst().map { rep in .init(title: shown(rep)) { [weak self] in self?.apply(issue, rep, in: el) } }
        }
        card.footer = footer
        panel.appearance = config.cardAppearance
        panel.show(card, below: anchor, avoid: marks.filter { $0.issue != issue }.map(\.rect))
    }

    /// The engine's message, unless it only repeats the fix already shown ("Did you mean \u{201C}test\u{201D}?").
    static func cardMessage(_ issue: Issue) -> String? {
        let m = issue.message.trimmingCharacters(in: .whitespaces)
        if m.isEmpty || m.hasPrefix("Did you mean") || m.hasPrefix("Change to") || m.hasPrefix("Cut \u{201C}") { return nil }
        if ["possible typo", "possible agreement error", "possible agreement error.", "agreement error", "compound",
            "grammatical error", "grammatical problem", "possible grammatical error"].contains(m.lowercased()) { return nil }
        return m
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
