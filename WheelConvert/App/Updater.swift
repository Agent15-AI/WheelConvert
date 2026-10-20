import AppKit
import Sparkle

/// Sparkle updates, checked automatically and from "Check for Updates…" in the menu. Builds without a
/// public signing key (development builds) don't check, since they couldn't verify an update.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    /// A version a scheduled check found while WheelConvert sat in the background; the menu offers it.
    private(set) var waitingVersion: String?

    func start() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no window of its own to show a scheduled update in, so unless WheelConvert is
    // in front, Sparkle leaves a gentle reminder: an item at the top of the menu.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.waitingVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.waitingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.waitingVersion = nil }
    }
}
