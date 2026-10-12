import AppKit
import SwiftUI
import ServiceManagement
import RedpenCore

/// Settings window. Changes save to config.json straight away.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { config.save(); onChange(config) } }
    @Published var openAtLogin: Bool {
        didSet {
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
    @Published var engineRunning: Bool?
    let onChange: (Config) -> Void

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        self.openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func checkEngine() { Task { engineRunning = await LanguageTool.isRunning() } }

    /// A comma-separated text field bound to a list of words.
    func list(_ path: WritableKeyPath<HouseStyle, [String]>) -> Binding<String> {
        Binding(get: { self.config.houseStyle[keyPath: path].joined(separator: ", ") },
                set: { self.config.houseStyle[keyPath: path] = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Check my writing", isOn: $model.config.enabled)
                Toggle("Open at login", isOn: $model.openAtLogin)
                LabeledContent("Grammar engine") {
                    switch model.engineRunning {
                    case .some(true): Text("LanguageTool running").foregroundStyle(.green)
                    case .some(false): Text("Not running. Run ./install.sh").foregroundStyle(.orange)
                    case .none: Text("Checking\u{2026}").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("No dashes (em dash, spaced en dash, --)", isOn: $model.config.houseStyle.noDashes)
                Toggle("Colons only for labels and lists", isOn: $model.config.houseStyle.colonsOnlyForLabels)
                Toggle("Flag sentences in another language", isOn: $model.config.houseStyle.flagOtherLanguages)
                TextField("Vague words to flag in long writing", text: model.list(\.containerWords), prompt: Text("framework, ecosystem, leverage"), axis: .vertical)
                TextField("Phrases to cut", text: model.list(\.disclaimers), prompt: Text("to be clear,"), axis: .vertical)
                Button("Use the example style") { model.config.houseStyle = .example }
            } header: {
                Text("House style")
            } footer: {
                Text("Optional rules on top of grammar, shown with a purple underline. All off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Notes for Claude", text: $model.config.houseStyle.deepCheckNotes, prompt: Text("Keep my short sentences."), axis: .vertical)
                TextField("Claude Code path", text: $model.config.claudePath)
                TextField("Model", text: $model.config.deepCheckModel)
            } header: {
                Text("Deep check with Claude")
            } footer: {
                Text("Uses Claude Code and your Claude subscription. Optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Button("Open settings file\u{2026}") { NSWorkspace.shared.open(Config.url) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { model.checkEngine() }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private var model: SettingsModel?

    func show(config: Config, onChange: @escaping (Config) -> Void) {
        let m = SettingsModel(config: config, onChange: onChange)
        model = m
        let host = NSHostingController(rootView: SettingsView(model: m))
        if window == nil {
            let w = NSWindow(contentViewController: host)
            w.title = "Redpen Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        } else {
            window?.contentViewController = host
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
