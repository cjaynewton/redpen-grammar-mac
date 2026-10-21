import Foundation
import Sparkle

/// Updates through Sparkle. Once a day Redpen asks the release page for the latest version number; nothing you
/// write is sent. A new version is checked against Redpen's signing key before it installs.
@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// The version waiting to install, found by the daily check. The menu shows it instead of popping up a window
    /// over whatever you are writing.
    @Published private(set) var waiting: String?

    /// Called once at launch. Only a built app (one with a feed address in its Info.plist) starts the updater,
    /// never `swift run` or the screenshot modes.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    func checkNow() { controller?.checkForUpdates(nil) }

    // A menu-bar app is rarely in front, so a daily check that finds an update marks the menu instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { if !handleShowingUpdate { waiting = version } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waiting = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waiting = nil }
    }
}
