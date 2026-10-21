import AppKit
import SwiftUI
import ServiceManagement
import RedpenCore

/// Settings, shown inside the Redpen menu: the menu slides to a Settings page, with pages for "When you click a
/// mistake" and Advanced, instead of opening a window. Changes save to config.json straight away.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { config.save(); onChange(config) } }
    @Published var openAtLogin: Bool {
        didSet {
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
    @Published var autoUpdate: Bool { didSet { Updates.shared.automatic = autoUpdate } }
    @Published var engineRunning: Bool?
    /// Whether each Deep check helper is ready, keyed "claude", "chatgpt", "gemini".
    @Published var helpers: [String: HelperRow.State] = [:]
    let onChange: (Config) -> Void

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        self.openAtLogin = SMAppService.mainApp.status == .enabled
        self.autoUpdate = Updates.shared.automatic
    }

    func checkEngine() { Task { engineRunning = await LanguageTool.isRunning() } }

    func checkHelpers() {
        let claudePath = config.claudeExecutable
        Task.detached {
            let found = ["claude": Helpers.claude(path: claudePath), "chatgpt": Helpers.codex(), "gemini": Helpers.gemini()]
            await MainActor.run { self.helpers = found }
        }
    }

    /// One style tip's switch.
    func tip(_ id: String) -> Binding<Bool> {
        Binding(get: { self.config.houseStyle.tips.contains(id) },
                set: { on in
                    var s = self.config.houseStyle.tips.filter { $0 != id }
                    if on { s.append(id) }
                    self.config.houseStyle.tips = s
                })
    }

    /// A whole group's switch: on when every tip in it is on; switching it sets them all.
    func group(_ g: StyleTip.Group) -> Binding<Bool> {
        let ids = g.tips.map(\.id)
        return Binding(get: { ids.allSatisfy(self.config.houseStyle.tips.contains) },
                       set: { on in
                           var s = self.config.houseStyle.tips.filter { !ids.contains($0) }
                           if on { s += ids }
                           self.config.houseStyle.tips = s
                       })
    }

    /// How many tips are on, for the Settings row.
    var tipsOn: Int { StyleTip.all.filter { config.houseStyle.tips.contains($0.id) }.count }

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

/// A page header: a back button on the left, the page's name in the middle.
struct NavHead: View {
    let back: String
    let title: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            HStack {
                Button(action: action) {
                    HStack(spacing: 2) { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)); Text(back) }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A small grey label over a group, like the Mac's own settings.
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).kerning(0.7).foregroundStyle(.tertiary)
            .padding(.horizontal, 4).padding(.bottom, -6)
    }
}

private struct Group<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 13) { content }
            .padding(.horizontal, 16).padding(.vertical, 14)
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
        HStack(alignment: .center, spacing: 12) {
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

/// A pop-up menu: it fits the narrow panel where a row of buttons would not.
private struct Choice: View {
    let label: String
    var sub: String = ""
    let options: [(String, String)]
    @Binding var value: String
    var body: some View {
        Row(label: label, sub: sub) {
            Picker(label, selection: $value) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }
}

/// A row that slides to another page.
private struct NextRow: View {
    let label: String
    var sub: String = ""
    var value: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Row(label: label, sub: sub) {
                HStack(spacing: 6) {
                    if !value.isEmpty { Text(value).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A page that scrolls when it is taller than the screen allows, and is only as tall as it needs otherwise.
private struct Scrolling<Content: View>: View {
    let full: Bool
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 400
    private var limit: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 60 }

    var body: some View {
        if full {
            content
        } else {
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(height, limit))
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var panel: PanelModel

    var body: some View {
        Scrolling(full: panel.rendering) {
            VStack(alignment: .leading, spacing: 14) {
                NavHead(back: "Redpen", title: "Settings") { panel.go(.main) }
                SectionLabel(text: "General")
                Group {
                    Switch(label: "Check my writing", on: $model.config.enabled)
                    Switch(label: "Open at login", on: $model.openAtLogin)
                    Row(label: "Check for updates", sub: "Once a day. Nothing you write is sent.") {
                        HStack(spacing: 10) {
                            Button("Check now") { Updates.shared.checkNow() }
                            Toggle("Check for updates", isOn: $model.autoUpdate).toggleStyle(.switch).labelsHidden().tint(.green)
                        }
                    }
                    Row(label: "Full grammar", sub: "LanguageTool, on this Mac") {
                        switch model.engineRunning {
                        case .some(true): Text("Running").foregroundStyle(.green)
                        case .some(false): Text("Off").foregroundStyle(.orange)
                        case .none: Text("Checking\u{2026}").foregroundStyle(.tertiary)
                        }
                    }
                }
                SectionLabel(text: "How mistakes show up")
                Group {
                    Row(label: "Underline",
                        sub: model.config.calm ? (model.tipsOn > 0 ? "Spelling and grammar in red, and the style tips you switched on"
                                                         : "Spelling and grammar only, in red")
                                             : "Spelling and grammar in red, style tips in purple") {
                        Picker("Underline", selection: $model.config.calm) {
                            Text("Mistakes only").tag(true)
                            Text("Mistakes and tips").tag(false)
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    Divider()
                    NextRow(label: "When you click a mistake", value: FixBoxPage.name(model.config.cardStyle)) { panel.go(.fixBox) }
                }
                SectionLabel(text: "Writing style")
                Group {
                    Switch(label: "No dashes", sub: "Flags em dashes and --", on: $model.config.houseStyle.noDashes)
                    Switch(label: "Colons for labels only", sub: "Flags a colon joining two sentences",
                           on: $model.config.houseStyle.colonsOnlyForLabels)
                    Switch(label: "Another language", sub: "Catches voice typing that switched language",
                           on: $model.config.houseStyle.flagOtherLanguages)
                    Choice(label: "Spelling", sub: Self.spellingNote(model.config.houseStyle.spelling),
                           options: [("Any", ""), ("Canadian", "en_CA"), ("American", "en_US"), ("British", "en_GB")],
                           value: $model.config.houseStyle.spelling)
                    Divider()
                    NextRow(label: "Style tips", sub: "Fillers, weasel words, passive voice and more",
                            value: model.tipsOn == 0 ? "Off" : "\(model.tipsOn) on") { panel.go(.styleTips) }
                }
                Group {
                    NextRow(label: "Advanced", sub: "Your own words and Deep check") { panel.go(.advanced) }
                }
                Text("Changes save as you make them").foregroundStyle(.tertiary)
                    .font(.system(size: 13)).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .frame(width: 400)
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

// MARK: - Style tips

/// The purple of style-tip underlines, for the examples on this page.
private let tipPurple = Color(nsColor: IssueKind.voice.color)

/// Optional purple underlines in three groups, each with a switch for the whole group and one per tip. The "i"
/// beside a tip opens its examples right under it, so a tip can be seen before it is switched on.
struct StyleTipsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var panel: PanelModel

    var body: some View {
        Scrolling(full: panel.rendering) {
            VStack(alignment: .leading, spacing: 14) {
                NavHead(back: "Settings", title: "Style tips") { panel.go(.settings) }
                Text("Purple underlines for writing that is correct but could be stronger. Tap i to see examples.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                ForEach(StyleTip.Group.allCases, id: \.self) { g in
                    SectionLabel(text: g.name)
                    Group {
                        Row(label: g.motto) {
                            Toggle(g.motto, isOn: model.group(g)).toggleStyle(.switch).labelsHidden().tint(.green)
                        }
                        .fontWeight(.semibold)
                        ForEach(g.tips, id: \.id) { tip in
                            Divider()
                            tipRow(tip)
                        }
                    }
                }
                Text("Your own words to flag stay in Advanced.").foregroundStyle(.tertiary)
                    .font(.system(size: 13)).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .frame(width: 400)
    }

    private func tipRow(_ tip: StyleTip) -> some View {
        let open = panel.openTip == tip.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.name)
                    Self.samples(tip).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { withAnimation(.easeOut(duration: 0.15)) { panel.openTip = open ? nil : tip.id } } label: {
                    InfoMark(on: open)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide examples for \(tip.name)" : "Show examples for \(tip.name)")
                Toggle(tip.name, isOn: model.tip(tip.id)).toggleStyle(.switch).labelsHidden().tint(.green)
            }
            if open, let ex = TipExamples.of(tip.id) { ExamplesView(examples: ex) }
        }
    }

    /// The tip's sample words in purple, so nobody has to know what "a hedge" is.
    static func samples(_ tip: StyleTip) -> Text {
        var t = Text("")
        for (i, w) in tip.samples.enumerated() {
            if i > 0 { t = t + Text(", ").foregroundColor(.secondary) }
            t = t + Text(TipExamples.curly(w)).foregroundColor(tipPurple)
        }
        if let b = tip.becomes { t = t + Text(" \u{2192} \(TipExamples.curly(b))").foregroundColor(.secondary) }
        return t
    }
}

/// The small circled "i" that opens a tip's examples.
struct InfoMark: View {
    var on: Bool
    var size: CGFloat = 20
    var body: some View {
        Text("i").font(.system(size: size * 0.6, weight: .semibold, design: .serif)).italic()
            .foregroundStyle(on ? Color.white : Color.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(on ? tipPurple : Color.clear))
            .overlay(Circle().stroke(on ? tipPurple : Color.secondary.opacity(0.7), lineWidth: 1.5))
            .contentShape(Circle())
    }
}

/// A tip's examples: why it matters, three or four before-and-after pairs, and when to leave the words alone.
struct ExamplesView: View {
    let examples: TipExamples

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TipExamples.curly(examples.why)).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(examples.pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.before(pair)).fixedSize(horizontal: false, vertical: true)
                    Text("becomes").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(Self.after(pair)).fixedSize(horizontal: false, vertical: true)
                }
                .font(Fonts.serif(15))
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
            }
            Text(TipExamples.curly(examples.leaveWhen)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.09)))
    }

    static func before(_ p: TipExamples.Pair) -> AttributedString {
        var out = AttributedString()
        for (t, marked) in p.beforeRuns {
            var a = AttributedString(t)
            a.foregroundColor = .secondary
            if marked { a.strikethroughStyle = .init(pattern: .solid, color: tipPurple) }
            out += a
        }
        return out
    }

    static func after(_ p: TipExamples.Pair) -> AttributedString {
        var out = AttributedString()
        for (t, marked) in p.afterRuns {
            var a = AttributedString(t)
            if marked { a.foregroundColor = tipPurple; a.backgroundColor = tipPurple.opacity(0.1) }
            out += a
        }
        return out
    }
}

// MARK: - When you click a mistake

/// The fix box's style, named for what the writer sees rather than what Redpen calls it.
struct FixBoxPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var panel: PanelModel
    @Environment(\.colorScheme) private var scheme

    static let styles: [(id: String, name: String, about: String)] = [
        ("roomy", "Just the fix", "The mistake, the fix and a short lesson."),
        ("sentence", "The fix in my sentence", "Your whole sentence, with the fix in place."),
        ("keyboard", "One by one, with the keyboard", "Return fixes, Esc skips, Tab goes to the next mistake."),
    ]

    static func name(_ style: String) -> String { styles.first { $0.id == style }?.name ?? styles[0].name }

    var body: some View {
        Scrolling(full: panel.rendering) {
        VStack(alignment: .leading, spacing: 14) {
            NavHead(back: "Settings", title: "When you click a mistake") { panel.go(.settings) }
            Group {
                ForEach(Self.styles, id: \.id) { s in
                    Button { model.config.cardStyle = s.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.config.cardStyle == s.id ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16)).foregroundStyle(model.config.cardStyle == s.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text(s.about).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Choice(label: "Colour", options: [("Light", "light"), ("Dark", "dark"), ("Match Mac", "system")],
                       value: $model.config.cardAppearance)
            }
            VStack(spacing: 8) {
                // Redraws when the style, the colour or the Mac's own light and dark change.
                if let img = SuggestionPanel.image(SuggestionPanel.sample, appearance: model.config.cardAppearance,
                                                   style: model.config.cardStyle) {
                    Image(nsImage: img)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                        .id("\(model.config.cardStyle)-\(model.config.cardAppearance)-\(scheme)")
                }
                Text("Actual size, drawn by Redpen").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.top, 18).padding(.bottom, 12).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(16)
        }
        .frame(width: 500)
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var panel: PanelModel

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        Scrolling(full: panel.rendering) {
            VStack(alignment: .leading, spacing: 14) {
                NavHead(back: "Settings", title: "Advanced") { panel.go(.settings) }
                SectionLabel(text: "Your own words")
                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Words to flag")
                            Text("Flagged in long writing, such as email and documents").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        Chips(words: $model.config.houseStyle.containerWords, prompt: "Add a word")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phrases to cut")
                        Chips(words: $model.config.houseStyle.disclaimers, prompt: "Add a phrase")
                    }
                }
                SectionLabel(text: "Deep check")
                Group {
                    Choice(label: "Check with", sub: helperNote,
                           options: [("Automatic", "auto"), ("Claude", "claude"), ("ChatGPT", "chatgpt"), ("Gemini", "gemini")], value: model.deepWith)
                    Row(label: "Speed", sub: speedNote) {
                        Picker("Speed", selection: model.deepSpeed) {
                            ForEach(speeds, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes for the editor")
                        TextEditor(text: $model.config.houseStyle.deepCheckNotes)
                            .font(Fonts.serif(14)).frame(height: 64).scrollContentBackground(.hidden)
                            .padding(6).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
                    }
                }
                Text("Deep check sends the text you check to the company behind the AI you pick (Anthropic, OpenAI or Google). Everything else stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                // The raw file is for the few who add a bank or block an app; it lives here, not on the everyday page.
                SectionLabel(text: "Settings file")
                Group {
                    Row(label: "Every setting as text", sub: "Including the banks and apps Redpen skips") {
                        HStack(spacing: 12) {
                            Button("Open") { panel.leave(); NSWorkspace.shared.open(Config.url) }
                            Button("Reload") { model.config = Config.load() }
                        }
                        .buttonStyle(.link)
                    }
                }
                HStack {
                    Text("Redpen Grammar \(version)").foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.system(size: 13)).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .frame(width: 400)
        .onAppear { model.checkHelpers() }
    }

    private var speeds: [(String, String)] {
        model.config.deepCheckWith == "claude" ? [("Fast", "fast"), ("Best", "best"), ("Fable", "fable")] : [("Fast", "fast"), ("Best", "best")]
    }

    private var helperNote: String {
        let who = model.config.deepCheckWith
        if who == "auto" {
            let ready = ["claude", "chatgpt", "gemini"].first { if case .connected = model.helpers[$0] { true } else { false } }
            return ready.map { "Uses \(Config.name($0)), the first one signed in" } ?? (model.helpers.isEmpty ? "Checking\u{2026}" : "Sign in to Claude, ChatGPT or Gemini first")
        }
        switch model.helpers[who] {
        case .none, .some(.checking): return "Checking\u{2026}"
        case .some(.notSetUp(let how)): return how
        case .some(.off): return "Not available on this Mac"
        case .some(.connected):
            switch who {
            case "chatgpt": return "Codex is signed in with ChatGPT"
            case "gemini": return "Uses Google\u{2019}s Antigravity CLI and your Google AI plan"
            default: return "Claude Code is signed in"
            }
        }
    }

    private var speedNote: String {
        let fast = model.config.deepCheckSpeed == "fast"
        switch model.config.deepCheckWith {
        case "auto": return fast ? "Quick answers, in a few seconds" : "Slower, more careful answers"
        case "chatgpt": return fast ? "Codex thinks briefly" : "Codex thinks it through, slower"
        case "gemini": return fast ? "Gemini thinks briefly" : "Gemini thinks it through, slower"
        default:
            if model.config.deepCheckSpeed == "fable" { return "For Claude plans that include Fable; weekly limit" }
            if model.config.deepCheckSpeed == "custom" { return "Using \(model.config.deepCheckModel) from your settings file" }
            return fast ? "Sonnet: quick and good" : "Opus: slower, closest to your voice"
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
