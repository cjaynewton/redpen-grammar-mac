import Foundation
import Sparkle

/// Updates through Sparkle. Once a day Redpen asks the release page for the latest version number; nothing you
/// write is sent. A new version is checked against Redpen's signing key before it installs.
@MainActor
enum Updates {
    private static var controller: SPUStandardUpdaterController?

    /// Called once at launch. Only a built app (one with a feed address in its Info.plist) starts the updater,
    /// never `swift run` or the screenshot modes.
    static func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    static func checkNow() { controller?.checkForUpdates(nil) }
}
