import AppKit
import SwiftUI
import ServiceManagement
import RedpenCore

/// Settings window: General, Fix box and Advanced tabs, drawn like the Redpen menu. Changes save to config.json
/// straight away.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { config.save(); onChange(config) } }
    @Published var openAtLogin: Bool {
        didSet {
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
    @Published var engineRunning: Bool?
    /// Whether each Deep check helper is ready, keyed "claude", "chatgpt", "gemini".
    @Published var helpers: [String: HelperRow.State] = [:]
    let onChange: (Config) -> Void
    /// Switches the window to a tab by index.
    var goTo: (Int) -> Void = { _ in }

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        self.openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func checkEngine() { Task { engineRunning = await LanguageTool.isRunning() } }

    func checkHelpers() {
        let claudePath = config.claudeExecutable
        Task.detached {
            let found = ["claude": Helpers.claude(path: claudePath), "chatgpt": Helpers.codex(), "gemini": Helpers.gemini()]
            await MainActor.run { self.helpers = found }
        }
    }

    /// One starter set's switch.
    func starter(_ id: String) -> Binding<Bool> {
        Binding(get: { self.config.houseStyle.starterSets.contains(id) },
                set: { on in
                    var s = self.config.houseStyle.starterSets.filter { $0 != id }
                    if on { s.append(id) }
                    self.config.houseStyle.starterSets = s
                })
    }

    /// Who runs Deep check. Fable is Claude only, so another helper falls back to Best.
    var deepWith: Binding<String> {
        Binding(get: { self.config.deepCheckWith },
                set: { w in
                    self.config.deepCheckWith = w
                    if w != "claude", self.config.deepCheckSpeed == "fable" { self.config.deepCheckSpeed = "best" }
                })
    }

    var deepSpeed: Binding<String> {
        Binding(get: { self.config.deepCheckSpeed },
                set: { s in
                    self.config.deepCheckSpeed = s
                    self.config.deepCheckModel = self.config.claudeModel
                })
    }
}

// MARK: - Shared pieces

/// The menu's look: solid paper, grey groups with a 4 point corner, a serif title.
private enum Look {
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.14, green: 0.145, blue: 0.16) : Color(red: 0.98, green: 0.98, blue: 0.973)
    }
    static let width: CGFloat = 560
}

private struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings").font(Fonts.serif(26, .semibold, italic: true))
                    Spacer()
                    Text("Changes save as you make them").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                content
            }
            .frame(width: Look.width - 40)
            .padding(20)
        }
        .font(.system(size: 14))
        .frame(width: Look.width)
        .frame(minHeight: 300, maxHeight: .infinity)
        .background(Look.paper(scheme))
    }
}

private struct GroupBox<Content: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(note).font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A label with an optional grey line under it, and its control on the right.
private struct Row<Control: View>: View {
    let label: String
    var sub: String = ""
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

private struct Switch: View {
    let label: String
    var sub: String = ""
    @Binding var on: Bool
    var body: some View {
        Row(label: label, sub: sub) { Toggle(label, isOn: $on).toggleStyle(.switch).labelsHidden().tint(.green) }
    }
}

private struct Segments: View {
    let label: String
    var sub: String = ""
    let options: [(String, String)]
    @Binding var value: String
    var body: some View {
        Row(label: label, sub: sub) {
            Picker(label, selection: $value) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

private struct Subhead: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @State private var open: Set<String> = []

    var body: some View {
        Page {
            GroupBox(title: "General") {
                Switch(label: "Check my writing", on: $model.config.enabled)
                Switch(label: "Open at login", on: $model.openAtLogin)
                Row(label: "Full grammar", sub: "LanguageTool, on this Mac") {
                    switch model.engineRunning {
                    case .some(true): Label("Running", systemImage: "circle.fill").labelStyle(Dot()).foregroundStyle(.green)
                    case .some(false): Text("Off. Turn it on from the Redpen menu.").foregroundStyle(.orange)
                    case .none: Text("Checking\u{2026}").foregroundStyle(.tertiary)
                    }
                }
            }
            GroupBox(title: "How mistakes show up", note: "Also in the Redpen menu") {
                Row(label: "What to underline",
                    sub: model.config.calm ? "Spelling and grammar only, in red" : "Spelling and grammar in red, style tips in purple") {
                    Picker("What to underline", selection: $model.config.calm) {
                        Text("Mistakes only").tag(true)
                        Text("Mistakes and tips").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(label: "Fix box", sub: "The box that opens when you click an underline") {
                    HStack(spacing: 10) {
                        Text(FixBoxTab.name(model.config.cardStyle)).foregroundStyle(.secondary)
                        Button("Change\u{2026}") { model.goTo(1) }
                    }
                }
            }
            GroupBox(title: "Writing style", note: "Purple underline, all optional") {
                Switch(label: "No dashes", sub: "Flags em dashes, spaced en dashes and --", on: $model.config.houseStyle.noDashes)
                Switch(label: "Colons only for labels and lists", sub: "Flags a colon used to join two sentences",
                       on: $model.config.houseStyle.colonsOnlyForLabels)
                Switch(label: "Sentences in another language", sub: "Catches voice typing that switched language",
                       on: $model.config.houseStyle.flagOtherLanguages)
                Divider()
                Segments(label: "Spelling", sub: Self.spellingNote(model.config.houseStyle.spelling),
                         options: [("Any", ""), ("Canadian", "en_CA"), ("American", "en_US"), ("British", "en_GB")],
                         value: $model.config.houseStyle.spelling)
                Divider()
                Subhead(text: "Starter sets")
                ForEach(StarterSet.all, id: \.id) { set in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.name)
                                HStack(spacing: 6) {
                                    Text(set.blurb).foregroundStyle(.secondary)
                                    Button(open.contains(set.id) ? "Hide the words" : "See the words") {
                                        if open.contains(set.id) { open.remove(set.id) } else { open.insert(set.id) }
                                    }
                                    .buttonStyle(.link)
                                }
                                .font(.system(size: 12.5))
                            }
                            Spacer(minLength: 8)
                            Toggle(set.name, isOn: model.starter(set.id)).toggleStyle(.switch).labelsHidden().tint(.green)
                        }
                        if open.contains(set.id) {
                            Text(set.wordList).font(Fonts.serif(14)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.1)))
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Want your own word lists or a second opinion from an AI? They are in").foregroundStyle(.secondary)
                Button("Advanced") { model.goTo(2) }.buttonStyle(.link)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
        }
        .onAppear { model.checkEngine() }
    }

    static func spellingNote(_ s: String) -> String {
        switch s {
        case "en_CA": "Suggests colour, centre"
        case "en_US": "Suggests color, center"
        case "en_GB": "Suggests colour, organise"
        default: "Accepts any English spelling"
        }
    }
}

/// A small coloured dot before the text, like the menu's status line.
private struct Dot: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

// MARK: - Fix box

struct FixBoxTab: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    static func name(_ style: String) -> String {
        style == "sentence" ? "Whole sentence" : style == "keyboard" ? "Keyboard" : "Simple"
    }

    static func about(_ style: String) -> String {
        switch style {
        case "sentence": "Your whole sentence with the fix shown in place, so you see the result before you accept."
        case "keyboard": "Built for going through a draft. Return fixes, Esc skips, Tab moves to the next mistake."
        default: "The mistake, the fix and a short lesson, with room to read. Good for most people."
        }
    }

    var body: some View {
        Page {
            GroupBox(title: "Fix box", note: "Opens when you click an underline") {
                Segments(label: "Style", options: [("Simple", "roomy"), ("Whole sentence", "sentence"), ("Keyboard", "keyboard")],
                         value: $model.config.cardStyle)
                Segments(label: "Colour", options: [("Light", "light"), ("Dark", "dark"), ("Match Mac", "system")],
                         value: $model.config.cardAppearance)
                Text(Self.about(model.config.cardStyle)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                // Redraws when the style, the colour or the Mac's own light and dark change.
                if let img = SuggestionPanel.image(SuggestionPanel.sample, appearance: model.config.cardAppearance,
                                                   style: model.config.cardStyle) {
                    Image(nsImage: img)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                        .id("\(model.config.cardStyle)-\(model.config.cardAppearance)-\(scheme)")
                }
                Text("Actual size, drawn by Redpen").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.top, 22).padding(.bottom, 14).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Advanced

struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        Page {
            GroupBox(title: "Your own words", note: "Purple underline, added to the starter sets") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Words to flag")
                    Text("Flagged in long writing, such as email and documents").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Chips(words: $model.config.houseStyle.containerWords, prompt: "Add a word")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Phrases to cut")
                    Chips(words: $model.config.houseStyle.disclaimers, prompt: "Add a phrase")
                }
            }
            GroupBox(title: "Deep check", note: "Optional, uses a plan you already pay for") {
                Segments(label: "Check with", sub: helperNote,
                         options: [("Claude", "claude"), ("ChatGPT", "chatgpt"), ("Gemini", "gemini")], value: model.deepWith)
                Segments(label: "Speed", sub: speedNote, options: speeds, value: model.deepSpeed)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes for the editor")
                    TextEditor(text: $model.config.houseStyle.deepCheckNotes)
                        .font(Fonts.serif(14)).frame(height: 70).scrollContentBackground(.hidden)
                        .padding(6).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
                }
            }
            HStack {
                Text("Redpen Grammar \(version)").foregroundStyle(.tertiary)
                Spacer()
                Button("Open settings file") { NSWorkspace.shared.open(Config.url) }.buttonStyle(.link)
                Button("Reload") { model.config = Config.load() }.buttonStyle(.link)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
        }
        .onAppear { model.checkHelpers() }
    }

    private var speeds: [(String, String)] {
        model.config.deepCheckWith == "claude" ? [("Fast", "fast"), ("Best", "best"), ("Fable", "fable")] : [("Fast", "fast"), ("Best", "best")]
    }

    private var helperNote: String {
        let who = model.config.deepCheckWith
        switch model.helpers[who] {
        case .none, .some(.checking): return "Checking\u{2026}"
        case .some(.notSetUp(let how)): return how
        case .some(.off): return "Not available on this Mac"
        case .some(.connected):
            switch who {
            case "chatgpt": return "Codex is installed and signed in with ChatGPT"
            case "gemini": return "Runs through Google\u{2019}s Antigravity CLI and your Google AI plan"
            default: return "Claude Code is installed and signed in"
            }
        }
    }

    private var speedNote: String {
        let fast = model.config.deepCheckSpeed == "fast"
        switch model.config.deepCheckWith {
        case "chatgpt": return fast ? "Fast: Codex thinks briefly" : "Best: Codex thinks it through, slower"
        case "gemini": return fast ? "Fast: Gemini thinks briefly" : "Best: Gemini thinks it through, slower"
        default:
            if model.config.deepCheckSpeed == "fable" { return "Fable: for Claude plans that include it; it has a weekly limit" }
            if model.config.deepCheckSpeed == "custom" { return "Using \(model.config.deepCheckModel) from your settings file" }
            return fast ? "Fast uses Sonnet: quick and good" : "Best uses Opus: slower, closest to your voice"
        }
    }
}

/// Words as removable tags, with a field to add more.
private struct Chips: View {
    @Binding var words: [String]
    let prompt: String
    @State private var draft = ""

    var body: some View {
        Flow(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 2) {
                    Text(w).font(Fonts.serif(14)).fixedSize(horizontal: false, vertical: true)
                    Button { words.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 18, height: 18)
                        .accessibilityLabel("Remove \(w)")
                }
                .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            }
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain).font(Fonts.serif(14)).frame(width: 120)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3])))
                .onSubmit {
                    let w = draft.trimmingCharacters(in: .whitespaces)
                    if !w.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { words.append(w) }
                    draft = ""
                }
        }
    }
}

/// Lays children out in lines, wrapping when a line is full.
private struct Flow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(proposal.width ?? 10_000, subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let fit = ProposedViewSize(width: bounds.width, height: nil)
                let s = subviews[i].sizeThatFits(fit)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, v) in subviews.enumerated() {
            // A tag wider than the row is offered the row's width, so its text wraps and its remove button stays in view.
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if w > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur = (cur.items + [i], w, max(cur.height, s.height))
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

// MARK: - Window

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private var model: SettingsModel?

    /// Draws each tab into a PNG without showing the window, for checking layout from the command line.
    /// `--render-settings out.png` writes out-general.png, out-fixbox.png and out-advanced.png.
    static func render(config: Config, to path: String) {
        let model = SettingsModel(config: config) { _ in }
        let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
        let tabs: [(String, AnyView)] = [("general", AnyView(GeneralTab(model: model))), ("fixbox", AnyView(FixBoxTab(model: model))),
                                         ("advanced", AnyView(AdvancedTab(model: model)))]
        for look in ["light", "dark"] {
            for (name, view) in tabs {
                let host = NSHostingController(rootView: view)
                host.sizingOptions = []
                host.view.frame = NSRect(origin: .zero, size: NSSize(width: Look.width, height: 1100))
                host.view.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                host.view.layoutSubtreeIfNeeded()
                let v = host.view
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(name)-\(look).png"))
            }
        }
    }

    /// 700 points tall, or less on a short screen; each tab scrolls inside.
    private static var size: NSSize {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return NSSize(width: Look.width, height: max(300, min(700, visible - 90)))
    }

    /// A Mac settings window: tabs with icons in the toolbar, the window titled after the open tab.
    /// The window sets the size, not the views, which scroll and would otherwise ask for no height.
    private static func makeTabs(_ m: SettingsModel) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let pages: [(String, String, AnyView)] = [
            ("General", "switch.2", AnyView(GeneralTab(model: m))),
            ("Fix box", "text.bubble", AnyView(FixBoxTab(model: m))),
            ("Advanced", "slider.horizontal.3", AnyView(AdvancedTab(model: m))),
        ]
        for (title, symbol, view) in pages {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            host.preferredContentSize = size
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        m.goTo = { [weak tabs] i in tabs?.selectedTabViewItemIndex = i }
        return tabs
    }

    func show(config: Config, onChange: @escaping (Config) -> Void) {
        let m = SettingsModel(config: config, onChange: onChange)
        model = m
        let tabs = Self.makeTabs(m)
        if let w = window {
            w.contentViewController = tabs
        } else {
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.setContentSize(Self.size)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Nothing focused on open: the Mac would otherwise put the cursor in a word field, and a stray keystroke lands there.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }
}
