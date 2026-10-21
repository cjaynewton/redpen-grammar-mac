import AppKit
import SwiftUI

/// Who made Redpen, which version this is, and where to report a problem.
enum About {
    static let project = URL(string: "https://github.com/cjaynewton/redpen-grammar-mac")!
    static let author = URL(string: "https://cedricatkinson.com")!

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    static var releaseNotes: URL { project.appendingPathComponent("releases/tag/v\(version)") }

    /// A new GitHub issue with a short form started and the facts filled in. Nothing you wrote goes in.
    static func issueURL(deepCheck: String) -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let chip = "Apple chip"
        #else
        let chip = "Intel"
        #endif
        let body = """
        **What happened?**


        **What did you expect?**


        **Which app were you typing in?**


        ---
        Redpen \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(chip)
        Deep check: \(deepCheck)
        """
        var c = URLComponents(url: project.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url!
    }
}

struct AboutPage: View {
    @ObservedObject var panel: PanelModel
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavHead(back: "Redpen", title: "About") { panel.go(.main) }
            VStack(spacing: 6) {
                // Until Redpen has its own icon, the generic app icon would look unfinished, so none shows.
                if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                }
                Text("Redpen Grammar").font(Fonts.serif(24, .semibold, italic: true))
                status.font(.system(size: 13))
            }
            .frame(maxWidth: .infinity).padding(.bottom, 4)
            box {
                line("Created by") { link("Cedric Atkinson", About.author) }
                Divider()
                line("Free and open source") { Text("MIT licence").foregroundStyle(.secondary) }
            }
            box {
                go("What's new in \(About.version)", About.releaseNotes)
                Divider()
                go("Project page on GitHub", About.project)
                Divider()
                go("Report an issue", About.issueURL(deepCheck: panel.deepName))
            }
            box {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thanks to")
                    Text("LanguageTool, the open-source grammar engine. The Newsreader typeface. Sparkle, for updates.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Provided as is. Your writing stays on your Mac unless you use Deep check.")
                .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
    }

    @ViewBuilder private var status: some View {
        if let v = updates.waiting {
            HStack(spacing: 8) {
                Text("Version \(About.version)").foregroundStyle(.secondary)
                Button("Install \(v)") { panel.leave(); updates.checkNow() }
            }
        } else if updates.lastChecked != nil {
            Text("Version \(About.version) \u{00B7} Up to date").foregroundStyle(.secondary)
        } else {
            Text("Version \(About.version)").foregroundStyle(.secondary)
        }
    }

    private func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }

    private func line<C: View>(_ label: String, @ViewBuilder _ value: () -> C) -> some View {
        HStack { Text(label); Spacer(); value() }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button(title) { panel.leave(); NSWorkspace.shared.open(url) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
    }

    private func go(_ title: String, _ url: URL) -> some View {
        Button { panel.leave(); NSWorkspace.shared.open(url) } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
