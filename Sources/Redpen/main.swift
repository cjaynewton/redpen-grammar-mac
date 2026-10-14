import AppKit
import ApplicationServices
import ServiceManagement
import RedpenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private var watcher: Watcher!
    private let deep = DeepCheck()
    private let patterns = PatternsWindow()
    private let welcome = WelcomeWindow()
    private let settings = SettingsWindow()
    private var lastDeepText: String?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        watcher = Watcher(config: Config.load())
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Redpen")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        if !AXIsProcessTrusted() || !watcher.config.welcomed {
            welcome.onDone = { [weak self] in
                guard let self else { return }
                self.watcher.config.welcomed = true
                self.watcher.config.save()
            }
            welcome.show()
        }
        watcher.start()
        hotKey = HotKey { [weak self] in self?.watcher.openNearest() }
        // Start at login by default, once; the menu toggle can turn it off and that choice sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    // Rebuilt each time it opens so the checkmarks and permission line are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The focused field must be read before the menu takes focus away.
        lastDeepText = watcher.textForDeepCheck()
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        if !trusted {
            menu.addItem(item("Allow Accessibility to start\u{2026}", #selector(showWelcome)))
            menu.addItem(.separator())
        }
        let on = item("Checking is on", #selector(toggle))
        on.state = watcher.config.enabled ? .on : .off
        menu.addItem(on)
        let deepItem = item("Deep check with Claude", #selector(deepCheck))
        deepItem.isEnabled = lastDeepText != nil
        menu.addItem(deepItem)
        let nearest = item("Fix mistake at cursor", #selector(fixNearest))
        nearest.keyEquivalent = "r"
        nearest.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(nearest)
        menu.addItem(item("Your patterns\u{2026}", #selector(showPatterns)))
        let look = NSMenuItem(title: "Card", action: nil, keyEquivalent: "")
        let looks = NSMenu()
        for (title, value) in [("Light", "light"), ("Dark", "dark"), ("Match Mac", "system")] {
            let i = item(title, #selector(setCardAppearance(_:)))
            i.representedObject = value
            i.state = watcher.config.cardAppearance == value ? .on : .off
            looks.addItem(i)
        }
        look.submenu = looks
        menu.addItem(look)
        menu.addItem(.separator())
        let model = NSMenuItem(title: AppleModel.isAvailable ? "Apple model: on" : "Apple model: off (spelling and rules only)",
                               action: nil, keyEquivalent: "")
        model.isEnabled = false
        menu.addItem(model)
        let login = item("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings\u{2026}", #selector(showSettings)))
        menu.addItem(item("Reload settings file", #selector(reloadSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Redpen", #selector(quit)))
    }

    @objc private func fixNearest() { watcher.openNearest() }

    @objc private func setCardAppearance(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        watcher.config.cardAppearance = v
        watcher.config.save()
    }

    private func item(_ t: String, _ a: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func toggle() {
        watcher.config.enabled.toggle()
        watcher.config.save()
        if !watcher.config.enabled { watcher.clear() }
    }

    @objc func showPatterns() { patterns.show(Mistakes.shared.report()) }

    @objc func deepCheck() {
        guard let t = lastDeepText else { return }
        deep.run(text: t, config: watcher.config)
    }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    @objc func showSettings() {
        settings.show(config: watcher.config) { [weak self] c in
            self?.watcher.config = c
            if !c.enabled { self?.watcher.clear() }
        }
    }
    @objc func showWelcome() { welcome.show() }
    @objc func reloadSettings() { watcher.config = Config.load() }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
