import AppKit
import Sparkle

/// Updates, through Sparkle: the only file that imports it.
///
/// Sparkle reads the update feed (`SUFeedURL`) and the public key that every update must be signed
/// with (`SUPublicEDKey`) from Info.plist; only a release build has them (see the Makefile), so a
/// development build makes no updater at all. Checks run on Sparkle's schedule, once a day.
///
/// Tutamak has no Dock icon and no window most of the time, so an update found by a scheduled check
/// is not pushed in front of whatever the person is doing. Sparkle hands it over (its "gentle
/// reminders"), the menu bar icon shows its dot, and the menu offers the update until it is looked at.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let feed: String
    private var controller: SPUStandardUpdaterController?
    /// The version a scheduled check found and is waiting to show, or nil.
    private(set) var waiting: String?
    /// Called when `waiting` changes.
    var onChange: () -> Void = {}

    init(feed: String) {
        self.feed = feed
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Opens Sparkle's window: what is new and the Install button, or "You're up to date".
    func check() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { feed }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the update itself only when it would not take focus from another app (right
    /// after launch); otherwise it waits in the menu.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        set(waiting: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        set(waiting: nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        set(waiting: nil)
    }

    private func set(waiting version: String?) {
        guard version != waiting else { return }
        waiting = version
        onChange()
    }
}
