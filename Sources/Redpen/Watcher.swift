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
    private var ltFailedAt = Date.distantPast        // last time LanguageTool gave no answer
    private var fixAllRunning = false
    private var navGen = 0                         // bumped on every field change, cancelling a pending next-mistake step
    private var watcherCard = false                // the open card is this watcher's (not Terminal's)
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
    private var reenabledAt: [pid_t: Date] = [:]
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
        navGen += 1
        if watcherCard { panel.hide(); watcherCard = false; cardMark = nil }
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
        guard let el = found else {
            Log.note("\(bid): no focused element (AX error \(err.rawValue))")
            if err == .noValue { reenableAccessibility(appEl, pid: app.processIdentifier, bundleID: bid) }
            lost(app.processIdentifier); return
        }
        let role: String = AX.attr(el, kAXRoleAttribute) ?? ""
        let subrole: String = AX.attr(el, kAXSubroleAttribute) ?? ""
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" { clear(); return }
        if let win = AX.element(appEl, kAXFocusedWindowAttribute), let title: String = AX.attr(win, kAXTitleAttribute),
           MoneyPages.isMoneyPage(title, words: config.excludedTitleWords) { clear(); return }

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

    /// The paragraphs LanguageTool checks and the key its result is stored under.
    private func ltSlice(_ el: AXUIElement, _ text: String) -> (key: String, slice: String, range: NSRange) {
        let ns = text as NSString
        let pr = ns.paragraphRange(for: window(el, text))
        let slice = ns.substring(with: pr)
        return ("\(pr.location)|\(slice)", slice, pr)
    }

    private func runLanguageTool(_ el: AXUIElement, _ text: String) {
        let (key, slice, pr) = ltSlice(el, text)
        guard key != ltKey, !ltInFlight, Date().timeIntervalSince(ltFailedAt) > 3 else { return }
        ltInFlight = true
        Task { @MainActor in
            defer { self.ltInFlight = false }
            // No answer (engine starting, timed out, or not LanguageTool): try this text again in a few seconds.
            guard let found = await LanguageTool.checkIfReady(slice) else { self.ltFailedAt = Date(); return }
            self.ltIssues = found.map { var i = $0; i.range = i.range.shifted(by: pr.location); return i }
            self.ltKey = key
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
            // Put the word each sentence needs first in spelling suggestions ("thougt" -> though or thought).
            _ = await Spelling.rank(Spelling.check(para), in: para)
            self.modelCache[para] = found
            self.inFlight.remove(para)
        }
    }

    /// All current issues with absolute ranges, minus ignored ones and the word still being typed.
    /// LanguageTool results count only for the exact text they were checked on. A grammar fix from older text can
    /// still match the same word in new text ("He are" edited to "We are" keeps "are"), so after any edit its
    /// underlines wait for the fresh check instead of offering advice that may no longer fit.
    private func currentIssues(_ el: AXUIElement, _ text: String) -> [Issue] {
        let lt = ltKey == ltSlice(el, text).key ? ltIssues : []
        let ns = text as NSString
        var model: [Issue] = []
        let w = ns.paragraphRange(for: window(el, text))
        ns.enumerateSubstrings(in: w, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let para = ns.substring(with: enclosing)
            if let found = self.modelCache[para] {
                model += found.map { var i = $0; i.range = i.range.shifted(by: enclosing.location); return i }
            }
        }
        let spelling = Engine.spellingAgreed(quickIssues, lt: lt).map { Spelling.applyPick($0, in: text) }
        var all = Engine.merge(spelling, Engine.protectNames(lt.filter { $0.kind != .spelling }, in: text))
        all = Engine.merge(all, Engine.protectNames(model, in: text))
        all = Engine.outsideQuotes(all, in: text)
        // Drop anything that no longer matches the text (it was edited since the check).
        all = all.filter { NSMaxRange($0.range) <= ns.length && ns.substring(with: $0.range) == $0.original }
        all = all.filter { !ignored.contains($0.ignoreKey) }
        if config.calm { all = Engine.calm(all) }
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
            Log.note("card closed: \(open.issue.kind) mistake \(now == nil ? "is gone" : "moved")")
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
        Log.note("shortcut: opened a \(issue.kind) mistake in \(bundleID)\(marks.contains { $0.issue == issue } ? "" : " (under the field)")")
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
            Log.note("click at \(Int(p.x)),\(Int(p.y)) in \(bundleID): \(marks.count) underlines, \(hit == nil ? "none hit" : "hit a \(hit!.issue.kind) mistake"), field \(element == nil ? "gone" : "held"), card \(action) [\(near.joined(separator: "; "))]")
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
                if #available(macOS 26, *), let t = await AppleModel.translate(issue.original) { i.replacements = [t] }
                self.showPanel(i, el, anchor)
            }
            return
        }
        showPanel(issue, el, anchor)
    }

    private func showPanel(_ incoming: Issue, _ el: AXUIElement, _ anchor: CGRect) {
        let all = currentIssues(el, lastText).sorted { $0.range.location < $1.range.location }
        // Build the card from the issue as it stands now, so its suggestions are never from older text.
        guard let issue = all.first(where: { $0.range == incoming.range && $0.original == incoming.original && $0.kind == incoming.kind })
                .map({ fresh -> Issue in var f = fresh; if f.replacements.isEmpty { f.replacements = incoming.replacements }; return f }) else {
            Log.note("card: that \(incoming.kind) mistake is gone"); return
        }
        let reps = issue.replacements.prefix(3).map { $0 }
        func shown(_ rep: String) -> String {
            let t = rep.trimmingCharacters(in: .whitespaces)
            return rep.isEmpty ? "Cut it" : t.isEmpty ? "Replace" : t
        }
        // Keyboard card: after a fix that landed, or a skip, open the next mistake in this same field.
        let keyboard = config.cardStyle == "keyboard"
        func fixing(_ rep: String) -> () -> Void {
            { [weak self] in
                guard let self else { return }
                // What the field should read once the fix is in, to confirm a paste that is only sent.
                let before: String? = AX.attr(el, kAXValueAttribute)
                guard self.apply(issue, rep, in: el) != nil else { return }
                let expected = before.flatMap { b -> String? in
                    let ns = b as NSString
                    return NSMaxRange(issue.range) <= ns.length ? ns.replacingCharacters(in: issue.range, with: rep) : nil
                }
                if keyboard, let expected { self.step(from: issue, 0, in: el, expecting: expected) }
            }
        }
        func use(_ rep: String) -> SuggestionPanel.Choice {
            .init(title: rep.isEmpty ? "Cut it" : "Use \u{201C}\(shown(rep))\u{201D}", run: fixing(rep))
        }
        var footer: [SuggestionPanel.Choice] = []
        if issue.kind == .spelling {
            footer.append(.init(title: "Add to dictionary") { [weak self] in
                Spelling.learn(issue.original); self?.lastQuickAt = .distantPast
            })
        }
        // More than one sure mistake in this paragraph: offer to fix them all at once.
        let paraRange = (lastText as NSString).paragraphRange(for: NSRange(location: min(issue.range.location, (lastText as NSString).length), length: 0))
        var fixAll: (count: Int, choice: SuggestionPanel.Choice)?
        if issue.kind != .voice, let n = Engine.fixAll(all, in: paraRange, of: lastText)?.fixed.count, n >= 2 {
            fixAll = (n, .init(title: "Fix all \(n)") { [weak self] in self?.fixAll(in: paraRange, el) })
        }
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
            card.alts = reps.dropFirst().map { rep in .init(title: shown(rep), run: fixing(rep)) }
        }
        card.footer = footer
        card.ignore = .init(title: "Ignore") { [weak self] in
            self?.ignored.insert(issue.ignoreKey)
            if keyboard { self?.step(from: issue, 0, in: el) }
        }
        card.fixAll = fixAll
        card.title = Self.cardTitle(issue)
        if let (s, at) = Spelling.sentence(around: issue.range, in: lastText), (s as NSString).length <= 280 {
            // Trailing spaces and line breaks only; the mistake's offset counts from the sentence's start.
            var text = s
            while let last = text.last, last.isWhitespace, (text as NSString).length > at + issue.range.length { text.removeLast() }
            card.sentence = (text, NSRange(location: at, length: issue.range.length), reps.first)
        }
        if let i = all.firstIndex(of: issue) { card.position = (i + 1, all.count) }
        card.onStep = { [weak self] dir in self?.step(from: issue, dir, in: el) }
        watcherCard = true
        panel.style = config.cardStyle
        panel.appearance = config.cardAppearance
        panel.show(card, below: anchor, avoid: marks.filter { $0.issue != issue }.map(\.rect))
    }

    /// What is wrong in a few words, the title on the Whole sentence card.
    static func cardTitle(_ issue: Issue) -> String {
        if issue.tentative { return "Maybe a mistake" }
        switch issue.kind {
        case .spelling: return issue.replacements.isEmpty ? "Unknown word" : "Misspelled word"
        case .grammar: return issue.replacements.first == "" ? "Extra word" : "Grammar fix"
        case .voice: return "One of your rules"
        }
    }

    /// Keyboard card: opens the next (1) or previous (-1) mistake, or after a fix or skip (0) the first one from
    /// that spot on. Only ever in the field the card was opened in: switching fields or apps cancels it, and after a
    /// fix it waits until the new text has been checked, so it never opens on positions from before the fix.
    /// `expecting`: the whole text as it should read after the fix just made. A paste is only sent, not confirmed,
    /// so the next card waits until the field reads exactly that, and stays put if it never does.
    private func step(from issue: Issue, _ dir: Int, in target: AXUIElement, expecting: String? = nil) {
        let ticket = navGen
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + (dir == 0 ? 0.3 : 0)) { [weak self] in
            self?.tryStep(from: issue, dir, in: target, ticket: ticket, started: started, expecting: expecting)
        }
    }

    private func tryStep(from issue: Issue, _ dir: Int, in target: AXUIElement, ticket: Int, started: Date, expecting: String?) {
        guard ticket == navGen, let el = element, CFEqual(el, target), stillFocused(target) else {
            Log.note("next mistake: cancelled, the field changed"); return
        }
        let live: String? = AX.attr(el, kAXValueAttribute)
        let fixIn = expecting.map { live == $0 } ?? true
        guard fixIn, live == lastText, !lastText.isEmpty, checked(el, lastText) else {
            if Date().timeIntervalSince(started) < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.tryStep(from: issue, dir, in: target, ticket: ticket, started: started, expecting: expecting)
                }
            } else { Log.note(fixIn ? "next mistake: gave up waiting for the check" : "next mistake: the fix never appeared, staying put") }
            return
        }
        let all = currentIssues(el, lastText).sorted { $0.range.location < $1.range.location }
        guard let firstIssue = all.first, let lastIssue = all.last else { return }
        let at = issue.range.location
        let pick: Issue
        switch dir {
        case -1: pick = all.last { $0.range.location < at } ?? lastIssue
        case 1: pick = all.first { $0.range.location > at } ?? firstIssue
        default: pick = all.first { $0.range.location >= at } ?? firstIssue
        }
        guard let anchor = marks.first(where: { $0.issue == pick })?.rect ?? lineRects(el, pick.range).first.map(AX.toCocoa) else { return }
        cardMark = marks.first { $0.issue == pick }
        open(pick, in: el, anchor: anchor)
    }

    /// True once this text has had its quick check and LanguageTool has answered for it. When LanguageTool is off
    /// or not answering, the quick check is enough.
    private func checked(_ el: AXUIElement, _ text: String) -> Bool {
        guard lastQuickAt >= lastChange else { return false }
        return ltKey == ltSlice(el, text).key || Date().timeIntervalSince(ltFailedAt) < 10
    }

    /// The engine's message, unless it only repeats the fix already shown ("Did you mean \u{201C}test\u{201D}?").
    static func cardMessage(_ issue: Issue) -> String? {
        let m = issue.message.trimmingCharacters(in: .whitespaces)
        if m.isEmpty || m.hasPrefix("Did you mean") || m.hasPrefix("Change to") || m.hasPrefix("Cut \u{201C}") { return nil }
        if ["possible typo", "possible agreement error", "possible agreement error.", "agreement error", "compound",
            "grammatical error", "grammatical problem", "possible grammatical error"].contains(m.lowercased()) { return nil }
        return m
    }

    /// Fixes every sure mistake in the paragraph at the cursor (Control-Option-Shift-R).
    func fixAllAtCursor() {
        if panel.isVisible { panel.hide() }
        guard let el = element, !lastText.isEmpty else { NSSound.beep(); return }
        let cur = AX.range(el, kAXSelectedTextRangeAttribute)?.location ?? 0
        let ns = lastText as NSString
        fixAll(in: ns.paragraphRange(for: NSRange(location: min(cur, ns.length), length: 0)), el)
    }

    /// Fixes each sure mistake on its own, last first so earlier positions stay put. Word by word keeps any bold or
    /// italics in the paragraph, which replacing the whole paragraph would lose. Apps that need the paste fallback
    /// get a pause between fixes so one paste never runs into the next.
    func fixAll(in range: NSRange, _ el: AXUIElement) {
        guard !fixAllRunning, let text: String = AX.attr(el, kAXValueAttribute),
              let result = Engine.fixAll(currentIssues(el, text), in: range, of: text) else { NSSound.beep(); return }
        panel.hide()
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Log.note("fix all: \(result.fixed.count) in \(bundleID)")
        fixAllRunning = true
        Task { @MainActor in
            defer { self.fixAllRunning = false }
            for i in result.fixed.reversed() {
                // Stop the moment the writer moves to another field or app: a paste would land there.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app, self.stillFocused(el) else {
                    Log.note("fix all: stopped, focus moved"); return
                }
                guard let pasted = self.apply(i, i.replacements[0], in: el) else { return }
                if pasted { try? await Task.sleep(for: .milliseconds(800)) }
            }
        }
    }

    /// True when `el` has focus right now, asked fresh from the Mac. When Word reports the page around the text as
    /// focused, the text area inside it is found the same way the watcher finds it, and must be `el` itself.
    func stillFocused(_ el: AXUIElement) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let live = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
            ?? AX.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        guard let live else { return false }
        if CFEqual(live, el) { return true }
        guard config.officeApps.contains(app.bundleIdentifier ?? ""),
              ["AXSplitGroup", "AXScrollArea", "AXGroup", "AXLayoutArea", "AXApplication", "AXWindow"].contains(AX.attr(live, kAXRoleAttribute) ?? ""),
              let inner = onlyTextArea(in: live) else { return false }
        return CFEqual(inner, el)
    }

    /// The text area inside a container only when there is no doubt: the search saw the whole container, exactly
    /// one control in it says it has focus, and that control is a text area. Nil whenever it would be a guess,
    /// including when nothing says it has focus.
    private func onlyTextArea(in root: AXUIElement) -> AXUIElement? {
        var focused: [AXUIElement] = []
        var visited = 0, complete = true
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard complete else { return }
            guard visited < 600 else { complete = false; return }
            visited += 1
            if let f: Bool = AX.attr(e, kAXFocusedAttribute), f { focused.append(e) }
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &ref)
            if err != .success && err != .noValue && err != .attributeUnsupported { complete = false; return }
            let kids = (ref as? [AXUIElement]) ?? []
            if !kids.isEmpty && depth >= 12 { complete = false; return }
            for c in kids { walk(c, depth + 1) }
        }
        walk(root, 0)
        guard complete, focused.count == 1, (AX.attr(focused[0], kAXRoleAttribute) ?? "") == "AXTextArea" else { return nil }
        return focused[0]
    }

    /// Replaces the text through Accessibility; falls back to select-and-paste for apps that refuse.
    /// Returns nil if nothing changed, false when written directly, true when it had to paste.
    @discardableResult
    func apply(_ issue: Issue, _ replacement: String, in el: AXUIElement) -> Bool? {
        guard let text: String = AX.attr(el, kAXValueAttribute) else { NSSound.beep(); return nil }
        let ns = text as NSString
        guard NSMaxRange(issue.range) <= ns.length, ns.substring(with: issue.range) == issue.original else { NSSound.beep(); return nil }
        guard AX.setRange(el, issue.range) else { NSSound.beep(); return nil }
        Mistakes.shared.record(issue, replacement: replacement, app: bundleID)
        let expected = ns.replacingCharacters(in: issue.range, with: replacement)
        if AX.set(el, kAXSelectedTextAttribute, replacement as CFString),
           let after: String = AX.attr(el, kAXValueAttribute), after == expected {
            lastText = ""
            return false
        }
        // Some apps (Electron, Office) ignore direct writes. Paste over the selection instead, but only if the
        // field is still the one in focus: Cmd+V goes wherever the cursor is now.
        guard stillFocused(el) else { Log.note("fix: not pasted, focus moved"); NSSound.beep(); return nil }
        Paste.replaceSelection(with: replacement)
        lastText = ""
        return true
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

    /// An Electron app can drop its accessibility tree while it keeps running (Claude's desktop app does after
    /// a reload), and then answers that nothing has focus. Asking again brings the text back. At most every 5 seconds.
    private func reenableAccessibility(_ appEl: AXUIElement, pid: pid_t, bundleID: String) {
        if let last = reenabledAt[pid], Date().timeIntervalSince(last) < 5 { return }
        reenabledAt[pid] = Date()
        enabledPids.remove(pid)
        enableAccessibility(appEl, pid: pid, bundleID: bundleID)
        Log.note("\(bundleID): asked again for its text")
    }

    /// One line for the menu panel: which app Redpen is reading and how many mistakes it can see.
    func statusLine() -> (text: String, live: Bool) {
        guard AXIsProcessTrusted() else { return ("Waiting for Accessibility permission", false) }
        guard element != nil, !bundleID.isEmpty else { return ("Click into some text and Redpen starts checking", false) }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        let n = Set(marks.map { $0.issue.range.location }).count
        return ("Checking \(name) \u{00B7} " + (n == 0 ? "no mistakes in view" : "\(n) mistake\(n == 1 ? "" : "s") in view"), true)
    }

    /// Text in the focused field for the deep check: the selection if there is one, else the paragraph at the cursor.
    /// Never the rest of the document, which may hold things the writer did not mean to send.
    func textForDeepCheck() -> String? {
        guard let el = element else { return nil }
        if let sel: String = AX.attr(el, kAXSelectedTextAttribute), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(sel.prefix(20000))
        }
        guard let t: String = AX.attr(el, kAXValueAttribute) else { return nil }
        let cur = AX.range(el, kAXSelectedTextRangeAttribute)?.location ?? 0
        let para = Engine.paragraph(in: t, at: cur).0
        return para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(para.prefix(20000))
    }
}

/// Puts text on the clipboard, presses Cmd+V, then restores what was there.
enum Paste {
    static let marker: Int64 = 0x5245_4450  // "REDP": lets Redpen ignore its own keystrokes

    /// The writer's own clipboard while Redpen borrows it, and the clipboard state Redpen last set.
    @MainActor private static var saved: [NSPasteboardItem]?
    @MainActor private static var ours = -1

    @MainActor
    static func replaceSelection(with s: String) {
        let pb = NSPasteboard.general
        // Snapshot only when the clipboard is the writer's. During back-to-back pastes it still holds Redpen's
        // previous fix, and the writer's original snapshot is kept instead.
        if saved == nil || pb.changeCount != ours {
            // Every item and every type (images, files, formatted text), not only plain text.
            saved = (pb.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
                return copy
            }
        }
        pb.clearContents()
        pb.setString(s, forType: .string)
        ours = pb.changeCount
        let mine = ours
        key(9, flags: .maskCommand)  // V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // A newer paste will restore later; and if the writer copied something new meanwhile, leave it.
            guard pb.changeCount == mine, ours == mine, let items = saved else { return }
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
            saved = nil
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
