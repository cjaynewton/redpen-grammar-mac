import AppKit
import SwiftUI
import RedpenCore

/// What the menu-bar panel needs from the rest of the app.
@MainActor
protocol PanelHost: AnyObject {
    var config: Config { get set }
    func statusLine() -> (text: String, live: Bool)
    func fixAtCursor()
    func fixAllAtCursor()
    func cleanUpAtCursor()
    func deepCheck()
    var canDeepCheck: Bool { get }
    func allowAccessibility()
}

/// One AI helper and whether Redpen can use it right now.
struct HelperRow: Identifiable, Equatable {
    enum State: Equatable { case checking, connected, notSetUp(String), off }
    let id: String
    let name: String
    let letter: String
    let tint: Color
    var state: State
}

@MainActor
final class PanelModel: ObservableObject {
    weak var host: PanelHost?
    @Published var enabled = true { didSet { guard enabled != oldValue else { return }; host?.config.enabled = enabled; host?.config.save() } }
    /// Which page the panel shows. Settings slides in place of the menu instead of opening a window.
    enum Page { case main, settings, fixBox, advanced, styleTips, about }
    @Published private(set) var page = Page.main { didSet { if page != oldValue { DispatchQueue.main.async { self.onLayoutChange?() } } } }
    /// The settings being edited, made fresh each time Settings opens so it starts from the saved file.
    @Published private(set) var settings: SettingsModel?
    /// The style tip whose examples are open on the Style tips page.
    @Published var openTip: String? { didSet { if openTip != oldValue, !rendering { DispatchQueue.main.async { self.onLayoutChange?() } } } }
    /// Set while drawing pages to PNG files: long pages draw in full instead of scrolling.
    var rendering = false
    var onLookChange: ((String) -> Void)?
    /// Closes the panel without handing focus back to the app you were writing in, for actions that open another app.
    var onLeave: (() -> Void)?
    func leave() { onLeave?() }
    var onLayoutChange: (() -> Void)?
    @Published var status = ""
    @Published var live = false
    @Published var trusted = true
    @Published var canDeepCheck = false
    @Published var deepName = "Claude"
    @Published var summary = PatternSummary([])
    @Published var showAll = false { didSet { if showAll != oldValue { DispatchQueue.main.async { self.onLayoutChange?() } } } }
    @Published var helpers: [HelperRow] = [
        HelperRow(id: "claude", name: "Claude", letter: "C", tint: Color(red: 0.79, green: 0.39, blue: 0.26), state: .checking),
        HelperRow(id: "chatgpt", name: "ChatGPT", letter: "G", tint: Color(red: 0.06, green: 0.64, blue: 0.50), state: .checking),
        HelperRow(id: "gemini", name: "Gemini", letter: "Ge", tint: Color(red: 0.26, green: 0.45, blue: 0.93), state: .checking),
        HelperRow(id: "apple", name: "Apple", letter: "A", tint: Color(white: 0.43), state: .checking),
    ]
    private var helpersCheckedAt = Date.distantPast

    /// Called each time the panel opens, so everything on it is current.
    func refresh() {
        guard let host else { return }
        trusted = AXIsProcessTrusted()
        enabled = host.config.enabled
        let s = host.statusLine()
        status = s.text; live = s.live
        canDeepCheck = host.canDeepCheck
        deepName = host.config.deepCheckWith == "auto" ? autoName() : host.config.deepCheckName
        summary = PatternSummary(Mistakes.shared.all(), words: WordLog.shared.all(), uncounted: Set(host.config.terminalApps))
        if Date().timeIntervalSince(helpersCheckedAt) > 300 { checkHelpers(claudePath: host.config.claudeExecutable) }
    }

    /// Asks Claude Code and Codex whether they are signed in. Both answer from local files, no network call.
    func checkHelpers(claudePath: String) {
        helpersCheckedAt = Date()
        set("apple", { if #available(macOS 26, *), AppleModel.isAvailable { return .connected } else { return .off } }())
        Task.detached {
            let claude = Helpers.claude(path: claudePath)
            let codex = Helpers.codex()
            let gemini = Helpers.gemini()
            await MainActor.run {
                self.set("claude", claude)
                self.set("chatgpt", codex)
                self.set("gemini", gemini)
                // On Automatic, the menu names the helper Deep check will actually use.
                if self.host?.config.deepCheckWith == "auto" { self.deepName = self.autoName() }
            }
        }
    }

    /// On Automatic, the first signed-in helper from the last check, in the order Deep check tries them.
    private func autoName() -> String {
        ["claude", "chatgpt", "gemini"].first { id in helpers.contains { $0.id == id && $0.state == .connected } }
            .map(Config.name) ?? "Claude"
    }

    /// Slides to a page. Opening Settings from the menu reads the saved settings first; back on the menu, the
    /// menu's own lines are refreshed from what Settings changed.
    func go(_ to: Page) {
        guard let host else { return }
        if to == .settings, page == .main {
            settings = SettingsModel(config: host.config) { [weak self] c in
                let look = self?.host?.config.cardAppearance
                self?.host?.config = c
                if c.cardAppearance != look { self?.onLookChange?(c.cardAppearance) }
                // A different fix box changes the preview's size, so the panel is measured and placed again.
                DispatchQueue.main.async { self?.onLayoutChange?() }
            }
        }
        let forward = to != .main && (page == .main || (page == .settings && to != .settings))
        withAnimation(.easeOut(duration: 0.2)) { direction = forward ? .trailing : .leading; page = to }
        if to == .main { settings = nil; refresh() }
        // Each page has its own size (the fix box page is wider), so the panel is measured and placed again.
        if !rendering { DispatchQueue.main.async { self.onLayoutChange?() } }
    }

    /// Esc on a page goes back one step; on the menu it closes the panel.
    func back() -> Bool {
        switch page {
        case .main: return false
        case .settings, .about: go(.main)
        case .fixBox, .advanced, .styleTips: go(.settings)
        }
        return true
    }

    /// The edge the next page slides in from.
    @Published var direction: Edge = .trailing

    func set(_ id: String, _ state: HelperRow.State) {
        if let i = helpers.firstIndex(where: { $0.id == id }) { helpers[i].state = state }
        DispatchQueue.main.async { self.onLayoutChange?() }
    }
}

enum Helpers {
    static func claude(path: String) -> HelperRow.State {
        guard FileManager.default.isExecutableFile(atPath: path) else { return .notSetUp("Install Claude Code to use your Claude plan") }
        let out = run(path, ["auth", "status", "--json"])
        return out.contains("\"loggedIn\": true") || out.contains("\"loggedIn\":true") ? .connected : .notSetUp("Sign in to Claude Code")
    }

    static func codex() -> HelperRow.State {
        guard let path = Config.firstExecutable("codex")
        else { return .notSetUp("Install Codex to use your ChatGPT plan") }
        return run(path, ["login", "status"]).localizedCaseInsensitiveContains("logged in using chatgpt") ? .connected : .notSetUp("Sign in to Codex with ChatGPT")
    }

    /// Google's Antigravity CLI has no sign-in status command, but listing its models asks you to sign in first.
    /// That one asks Google's servers, so it runs in the background like the other checks.
    static func gemini() -> HelperRow.State {
        guard let path = Config.firstExecutable("agy") else { return .notSetUp("Install Google\u{2019}s Antigravity CLI to use your Google AI plan") }
        return run(path, ["models"]).localizedCaseInsensitiveContains("sign in") ? .notSetUp("Sign in: open Terminal, run agy once") : .connected
    }

    /// Runs a helper with fixed arguments (never through a shell) and returns what it printed.
    /// Gives up after `limit` seconds and returns nothing, which reads as not set up.
    static func run(_ path: String, _ args: [String], limit: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return "" }
        // Read in the background so a helper that stalls (a network or sign-in problem) can be given up on.
        let box = OutputBox()
        let reader = out.fileHandleForReading
        DispatchQueue.global().async { box.set(reader.readDataToEndOfFile()) }
        if done.wait(timeout: .now() + limit) == .timedOut { p.terminate(); return "" }
        return String(decoding: box.wait(seconds: 2), as: UTF8.self)
    }
}

/// A helper's output, handed from the reading thread to the waiting one.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let ready = DispatchSemaphore(value: 0)
    func set(_ d: Data) { lock.withLock { data = d }; ready.signal() }
    func wait(seconds: Double) -> Data { _ = ready.wait(timeout: .now() + seconds); return lock.withLock { data } }
}

// MARK: - View

/// The serif used for writing and corrections: Newsreader, the serif on cedricatkinson.com, shipped inside the
/// app under its open font licence (Oct 14 2026). REDPEN_SERIF=system goes back to New York, the Mac's own serif,
/// and so does a missing font file.
enum Fonts {
    /// Loads the fonts bundled in Redpen.app/Contents/Resources/Fonts for this app only. Call once at launch.
    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }

    static let useNewsreader: Bool = ProcessInfo.processInfo.environment["REDPEN_SERIF"] != "system"
        && NSFont(name: "Newsreader16pt-Regular", size: 12) != nil
    /// Newsreader's lowercase is shorter than New York's; 10% larger reads at the same size.
    static var scale: CGFloat { useNewsreader ? 1.1 : 1 }

    /// The menu bar mark: the app icon's Gloock "r." without its tile (Resources/Icon/icon-source.html, same
    /// placement), drawn as a template so the Mac colours it for a light or dark menu bar. Nil if Gloock is missing.
    static func menuBarMark() -> NSImage? {
        let font = CTFontCreateWithName("Gloock-Regular" as CFString, 600, nil)
        guard CTFontCopyPostScriptName(font) as String == "Gloock-Regular" else { return nil }
        let chars = Array("r".utf16)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, chars, &glyph, 1) else { return nil }
        // Placed as in the icon drawing, with the baseline at 0: the letter centred on x 470, the dot at x 690 and
        // 38 above the baseline.
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], nil, 1)
        var at = CGAffineTransform(translationX: 470 - advance / 2, y: 0)
        guard let letter = CTFontCreatePathForGlyph(font, glyph, &at) else { return nil }
        let mark = CGMutablePath()
        mark.addPath(letter)
        mark.addEllipse(in: CGRect(x: 690 - 52, y: 38 - 52, width: 104, height: 104))
        let box = mark.boundingBoxOfPath
        let height: CGFloat = 12, s = height / box.height
        let image = NSImage(size: NSSize(width: ceil(box.width * s) + 2, height: 18), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.translateBy(x: (rect.width - box.width * s) / 2, y: (rect.height - height) / 2)
            cg.scaleBy(x: s, y: s)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.addPath(mark)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Redpen"
        return image
    }

    /// The exact style, named outright: a family-wide lookup picked italic for upright text.
    static func styleName(bold: Bool, medium: Bool, italic: Bool) -> String? {
        guard useNewsreader else { return nil }
        let w = bold ? "SemiBold" : medium ? "Medium" : ""
        return "Newsreader16pt-" + (w.isEmpty ? (italic ? "Italic" : "Regular") : w + (italic ? "Italic" : ""))
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        if let name = styleName(bold: weight == .semibold || weight == .bold, medium: weight == .medium, italic: italic) {
            return .custom(name, fixedSize: size * scale)
        }
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var updates = Updates.shared
    var close: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private static let red = Color(red: 0.85, green: 0.20, blue: 0.19)
    private static let blue = Color(red: 0.16, green: 0.44, blue: 0.86)

    var body: some View {
        ZStack(alignment: .top) {
            switch model.page {
            case .main: menu.transition(.push(from: model.direction))
            case .settings: model.settings.map { SettingsPage(model: $0, panel: model).transition(.push(from: model.direction)) }
            case .fixBox: model.settings.map { FixBoxPage(model: $0, panel: model).transition(.push(from: model.direction)) }
            case .advanced: model.settings.map { AdvancedPage(model: $0, panel: model).transition(.push(from: model.direction)) }
            case .styleTips: model.settings.map { StyleTipsPage(model: $0, panel: model).transition(.push(from: model.direction)) }
            case .about: AboutPage(panel: model).transition(.push(from: model.direction))
            }
        }
        .clipped()
        .font(.system(size: 14))
        // Solid paper, not the system's see-through glass: the page behind made the panel hard to read.
        .background(scheme == .dark ? Color(red: 0.14, green: 0.145, blue: 0.16) : Color(red: 0.98, green: 0.98, blue: 0.973))
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let v = updates.waiting { updateBanner(v) }
            header
            if !model.trusted { permission }
            group { actions }
            group { patterns }
            group { helpers }
            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Redpen").font(Fonts.serif(21, .semibold, italic: true))
                Spacer()
                Toggle("Checking", isOn: $model.enabled).toggleStyle(.switch).labelsHidden().tint(.green)
            }
            HStack(spacing: 8) {
                Circle().fill(model.enabled && model.live ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                Text(model.enabled ? model.status : "Checking is off").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    /// A waiting update across the top of the menu, so it is the first thing seen when the menu opens.
    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Redpen \(version) is ready").fontWeight(.semibold)
                Text("Installs in a few seconds, then Redpen restarts").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Install") { model.leave(); updates.checkNow() }
                .buttonStyle(.borderedProminent).tint(.accentColor).controlSize(.regular)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.35)))
    }

    private var permission: some View {
        group {
            Text("Redpen needs Accessibility permission to read what you type.").fixedSize(horizontal: false, vertical: true)
            Button("Allow Accessibility\u{2026}") { close(); model.host?.allowAccessibility() }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Fix mistake at cursor", key: "\u{2303}\u{2325}R") { close(); model.host?.fixAtCursor() }
            row("Fix all in this paragraph", key: "\u{2303}\u{2325}\u{21E7}R") { close(); model.host?.fixAllAtCursor() }
            row("Clean up this paragraph", key: "\u{2303}\u{2325}C") { close(); model.host?.cleanUpAtCursor() }
            row("Deep check with \(model.deepName)", key: nil) { close(); model.host?.deepCheck() }
                .disabled(!model.canDeepCheck)
        }
    }

    private func row(_ title: String, key: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let key { Text(key).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(_ t: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(note).font(.system(size: 13)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var patterns: some View {
        title("Your patterns", "This week")
        if model.summary.rows.isEmpty {
            Text("Each fix you accept shows up here, so you can see which mistakes keep coming back.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(model.summary.thisWeek)").font(Fonts.serif(32, .semibold)).monospacedDigit()
                Text("fix\(model.summary.thisWeek == 1 ? "" : "es") this week, \(model.summary.lastWeek) the week before").foregroundStyle(.secondary)
            }
            if let line = model.summary.rateLine {
                Text(line).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((model.showAll ? model.summary.rows : Array(model.summary.rows.prefix(3))).enumerated()), id: \.offset) { _, r in
                patternRow(r)
            }
            if model.summary.rows.count > 3 {
                Button(model.showAll ? "Show fewer" : "See all \(model.summary.rows.count) patterns") { model.showAll.toggle() }
                    .buttonStyle(.plain).foregroundStyle(Self.blue)
            }
        }
    }

    private func patternRow(_ r: PatternSummary.Row) -> some View {
        let tint = r.spelling ? Self.red : Self.blue
        let wordy = r.original.count > 24 || r.replacement.count > 24
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if wordy {
                        Text(r.title.prefix(1).uppercased() + r.title.dropFirst())
                    } else {
                        Text(r.original).strikethrough(color: tint).foregroundColor(.secondary)
                        + Text("  \u{2192}  ").foregroundColor(.secondary)
                        + Text(r.replacement.isEmpty ? "(cut)" : r.replacement).font(Fonts.serif(17, italic: true)).foregroundColor(tint)
                    }
                }
                .font(Fonts.serif(17))
                Text(r.perWords ? r.trend : "\(r.thisWeek) time\(r.thisWeek == 1 ? "" : "s") \u{00B7} \(r.trend)").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            spark(r.weeks, tint: tint)
        }
    }

    private func spark(_ weeks: [Int], tint: Color) -> some View {
        let top = max(weeks.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { i, n in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i == weeks.count - 1 ? tint : Color.secondary.opacity(0.45))
                    .frame(width: 5, height: max(3, 22 * CGFloat(n) / CGFloat(top)))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityLabel("Last eight weeks: \(weeks.map(String.init).joined(separator: ", "))")
    }

    @ViewBuilder private var helpers: some View {
        title("AI helpers", "Who checks and rewrites")
        EngineRow(engine: GrammarEngine.shared)
        ForEach(model.helpers) { h in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(h.letter).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(h.tint, in: RoundedRectangle(cornerRadius: 4))
                    Text(h.name).fontWeight(.semibold)
                    Spacer()
                    stateText(h)
                }
                if case .notSetUp(let how) = h.state {
                    Text(how).font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 38)
                }
            }
        }
    }

    private func stateText(_ h: HelperRow) -> some View {
        switch h.state {
        case .checking: return Text("Checking\u{2026}").foregroundStyle(.tertiary)
        case .connected: return Text(h.id == "apple" ? "On this Mac" : "Connected").foregroundStyle(.green)
        case .notSetUp: return Text("Not set up").foregroundStyle(.orange)
        case .off: return Text("Off on this Mac").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let v = updates.waiting {
                // An update found by the daily check waits here rather than interrupting your writing.
                Button("Update to \(v) \u{203A}") { model.leave(); updates.checkNow() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 13, weight: .medium))
            } else {
                Text("Redpen \(About.version)").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Settings") { model.go(.settings) }
            // Quit lives in here so nobody turns checking off by accident.
            Menu("Options") {
                Button("Check for Updates\u{2026}") { model.leave(); updates.checkNow() }
                Button("Report an Issue\u{2026}") { model.leave(); NSWorkspace.shared.open(About.issueURL(deepCheck: model.deepName)) }
                Button("About Redpen Grammar") { model.go(.about) }
                Divider()
                Button("Quit Redpen") { NSApp.terminate(nil) }
            }
            .menuStyle(.button).fixedSize()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Panel window

/// A borderless window that can take clicks and keys, for the menu panel.
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel that opens from the pencil in the menu bar. Redpen places it itself, hanging from the pencil
/// and kept inside the screen: the system popover cut its top off on a multi-monitor setup (Oct 14 2026).
/// It hands focus back to the app you were typing in when it closes, so a fix or a deep check acts there.
@MainActor
final class MenuPanel: NSObject, NSWindowDelegate {
    let model = PanelModel()
    private let window: PanelWindow
    private let hosting: NSHostingView<AnyView>
    private var previous: NSRunningApplication?
    private weak var button: NSStatusBarButton?
    private var outsideClicks: Any?
    private var escapeKey: Any?

    init(host: PanelHost) {
        window = PanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        model.host = host
        hosting.rootView = AnyView(PanelView(model: model) { [weak self] in self?.close() })
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // An NSPanel hides itself without a word when its app stops being active, which looked like the menu
        // vanishing. It stays put instead, and losing focus closes it through close(), which logs why.
        window.hidesOnDeactivate = false
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            let to = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            MainActor.assumeIsolated { self?.close("Redpen stopped being the active app, \(to) took over", restoreFocus: false) }
        }
        model.onLookChange = { [weak self] look in self?.applyLook(look) }
        model.onLayoutChange = { [weak self] in self?.place() }
        model.onLeave = { [weak self] in self?.close("opened another app", restoreFocus: false) }
    }

    var isShown: Bool { window.isVisible }

    func toggle(from button: NSStatusBarButton) {
        if window.isVisible { close("pencil clicked"); return }
        self.button = button
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : front
        model.refresh()
        applyLook(model.host?.config.cardAppearance ?? "light")
        place()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation, f = self.window.frame
                let at = "\(Int(p.x)),\(Int(p.y)), panel \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                // A click another app received inside the panel's own frame is not the writer leaving the menu.
                if f.contains(p) { Log.note("menu panel: a click at \(at) went to another app; kept open"); return }
                self.close("click outside at \(at)")
            }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                MainActor.assumeIsolated { if self?.model.back() != true { self?.close("Esc") } }
                return nil
            }
            return e
        }
    }

    /// Top edge just under the pencil, right edge lined up with it, the whole panel inside the visible screen.
    private func place() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let button, let bw = button.window else { return }
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(b) } ?? bw.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? b
        var x = b.midX - size.width / 2
        x = min(max(x, vf.minX + 6), vf.maxX - size.width - 6)
        var top = min(b.minY - 6, vf.maxY - 6)
        if top - size.height < vf.minY + 6 { top = min(vf.maxY - 6, vf.minY + 6 + size.height) }
        window.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        Log.note("menu panel \(model.page) at \(Int(x)),\(Int(top - size.height)) size \(Int(size.width))x\(Int(size.height))")
    }

    private func applyLook(_ look: String) {
        let a = look == "system" ? nil : NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        window.appearance = a
        hosting.appearance = a
    }

    func close(_ why: String = "closed", restoreFocus: Bool = true) {
        guard window.isVisible else { return }
        Log.note("menu panel closed: \(why), on \(model.page)")
        window.orderOut(nil)
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        if let m = escapeKey { NSEvent.removeMonitor(m); escapeKey = nil }
        model.showAll = false
        if model.page != .main { model.go(.main) }
        if restoreFocus { previous?.activate() }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close("lost focus") }
    }

    /// Draws the panel into PNG files without showing it, so its layout can be checked from the command line.
    /// The menu goes to `prefix-light.png` and `prefix-dark.png`; other pages to `prefix-settings-light.png` and so on.
    static func render(host: PanelHost, to prefix: String, pages: [PanelModel.Page] = [.main]) {
        // Give the grammar engine row its real answer rather than "Checking…".
        GrammarEngine.shared.startIfInstalled()
        if let v = ProcessInfo.processInfo.environment["REDPEN_FAKE_UPDATE"], !v.isEmpty { Updates.shared.pretendWaiting(v) }
        let until = Date().addingTimeInterval(5)
        while GrammarEngine.shared.state == .checking, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        for page in pages { render(host: host, to: page == .main ? prefix : "\(prefix)-\(page)", page: page) }
        // The Style tips page again with one tip's examples open.
        if pages.contains(.styleTips) { render(host: host, to: "\(prefix)-styleTips-open", page: .styleTips, openTip: "unsourced") }
    }

    private static func render(host: PanelHost, to prefix: String, page: PanelModel.Page, openTip: String? = nil) {
        let model = PanelModel()
        model.host = host
        model.rendering = true
        model.openTip = openTip
        model.refresh()
        if page == .about { model.go(.about) } else if page != .main { model.go(.settings) }
        if page == .fixBox || page == .advanced || page == .styleTips { model.go(page) }
        model.set("claude", Helpers.claude(path: host.config.claudeExecutable))
        model.set("chatgpt", Helpers.codex())
        model.set("gemini", Helpers.gemini())
        // Settings asks the engine when it appears, which an offscreen render never does.
        if let s = model.settings {
            s.checkEngine()
            let until = Date().addingTimeInterval(5)
            while s.engineRunning == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        for look in ["light", "dark"] {
            // The real popover paints its own background; the test render needs one behind the view.
            let view = NSHostingView(rootView: PanelView(model: model))
            view.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
            let size = view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = view.appearance
            window.backgroundColor = look == "dark" ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(look).png"))
        }
    }
}

/// The full grammar engine's row: on, or a one-click download when it isn't here yet.
struct EngineRow: View {
    @ObservedObject var engine: GrammarEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("L").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Color(red: 0.25, green: 0.38, blue: 0.62), in: RoundedRectangle(cornerRadius: 4))
                Text("Full grammar").fontWeight(.semibold)
                Spacer()
                status
            }
            detail.font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 38)
        }
    }

    @ViewBuilder private var status: some View {
        switch engine.state {
        case .checking: Text("Checking\u{2026}").foregroundStyle(.tertiary)
        case .running: Text("On this Mac").foregroundStyle(.green)
        case .starting: Text("Starting\u{2026}").foregroundStyle(.secondary)
        case .downloading(let f): Text("\(Int(f * 100))%").foregroundStyle(.secondary).monospacedDigit()
        case .missing, .failed: Button("Turn on") { engine.install() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch engine.state {
        case .missing: Text("Thousands more grammar rules. One download, about 300 MB, then it runs on this Mac.")
        case .downloading: ProgressView(value: { if case .downloading(let f) = engine.state { return f } else { return 0 } }()).controlSize(.small)
        case .failed(let why): Text(why)
        default: EmptyView()
        }
    }
}
