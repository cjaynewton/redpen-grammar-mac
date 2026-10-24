import AppKit
import RedpenCore

/// Live test of Deep check's Replace in a real app, for maintainers. Put a document in front holding the four test
/// paragraphs below, then `open -n "Redpen Grammar.app" --args --replace-test results.txt` (opened as an app, so the
/// app's own Accessibility permission applies). No AI is asked; the revised text is fixed.
/// It replaces one paragraph, then checks that an edit made during a check makes Replace refuse and change nothing.
@MainActor
enum ReplaceTest {
    static let paragraphs = ["Dear Sam,", "Their going home now.", "Its a test.", "Thanks"]

    static func run(_ w: Watcher, results path: String) {
        w.start()
        resultsPath = path
        Task { @MainActor in
            var fails = 0
            func check(_ name: String, _ ok: Bool) { print(ok ? "  pass" : "  FAIL", name); if !ok { fails += 1 } }
            func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
            guard AXIsProcessTrusted() else { print("NOT TRUSTED: Redpen needs Accessibility"); exit(2) }
            guard let front = NSWorkspace.shared.frontmostApplication else { print("FAIL no app in front"); exit(1) }
            print("app: \(front.localizedName ?? "?") (\(front.bundleIdentifier ?? "?"))")
            let appEl = AXUIElementCreateApplication(front.processIdentifier)
            AX.set(appEl, "AXManualAccessibility", kCFBooleanTrue)
            AX.set(appEl, "AXEnhancedUserInterface", kCFBooleanTrue)
            await pause(1)
            guard let field = find(in: appEl, containing: paragraphs[1]) else { print("FAIL no field holding the test text"); exit(1) }
            AX.set(field, kAXFocusedAttribute, kCFBooleanTrue)
            func value() -> String { AX.attr(field, kAXValueAttribute) ?? "" }
            func caret(_ marker: String) -> Bool {
                let r = (value() as NSString).range(of: marker)
                return r.location != NSNotFound && AX.setRange(field, NSRange(location: r.location + 2, length: 0))
            }
            await pause(1.5)  // the watcher picks up the field

            // 1. Replace one paragraph.
            check("caret into the second paragraph", caret("Their going"))
            await pause(0.6)
            guard let t = w.targetForDeepCheck() else { print("FAIL Redpen didn't see the field"); exit(1) }
            check("Deep check takes exactly that paragraph", t.text == paragraphs[1])
            let r1 = w.replace(t, with: "They're going home now.")
            if case .refused(let why) = r1 { print("    refused: \(why)") }
            if case .done(let pasted) = r1 { print("    written \(pasted ? "by paste" : "directly")") }
            await pause(1.5)
            let after = value()
            check("Replace put the revised paragraph in", after.contains("They're going home now.") && !after.contains("Their going"))
            check("the other paragraphs are untouched", [paragraphs[0], paragraphs[2], paragraphs[3]].allSatisfy(after.contains))

            // 2. An edit while the check runs: Replace must refuse and change nothing.
            check("caret into the third paragraph", caret("Its a test"))
            await pause(0.6)
            guard let t2 = w.targetForDeepCheck() else { print("FAIL Redpen lost the field"); exit(1) }
            check("Deep check takes the third paragraph", t2.text == paragraphs[2])
            let end = (value() as NSString).length
            _ = AX.setRange(field, NSRange(location: end, length: 0))
            if !AX.set(field, kAXSelectedTextAttribute, " Bye." as CFString) || !value().hasSuffix(" Bye.") { Paste.type(" Bye.") }
            await pause(1)
            let edited = value()
            check("the test edit went in", edited.contains("Bye."))
            let r2 = w.replace(t2, with: "It's a test.")
            if case .refused = r2 { check("Replace refuses after an edit", true) } else { check("Replace refuses after an edit", false) }
            await pause(1.5)
            check("nothing changed after the refusal", value() == edited)
            print(fails == 0 ? "replace test: all pass" : "replace test: \(fails) failed")
            exit(fails == 0 ? 0 : 1)
        }
    }

    // A one-shot maintainer test: it runs alone on the main thread, so plain storage is enough.
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var resultsPath = ""
    nonisolated private static func print(_ items: Any...) { lines.append(items.map { "\($0)" }.joined(separator: " ")) }
    nonisolated private static func exit(_ code: Int32) -> Never {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: resultsPath, atomically: true, encoding: .utf8)
        Darwin.exit(code)
    }

    /// The deepest text element in the focused window whose text holds `marker`.
    private static func find(in appEl: AXUIElement, containing marker: String) -> AXUIElement? {
        guard let win = AX.element(appEl, kAXFocusedWindowAttribute) ?? AX.element(appEl, kAXMainWindowAttribute) else { return nil }
        var best: AXUIElement?
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard visited < 4000, depth < 40 else { return }
            visited += 1
            let role: String = AX.attr(e, kAXRoleAttribute) ?? ""
            if ["AXTextArea", "AXTextField", "AXWebArea", "AXGroup"].contains(role),
               let v: String = AX.attr(e, kAXValueAttribute), v.contains(marker) { best = e }
            for c in (AX.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
        }
        walk(win, 0)
        return best
    }
}
