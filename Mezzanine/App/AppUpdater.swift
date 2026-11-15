import SwiftUI
import Sparkle

/// Software updates through Sparkle, in Release builds only (Debug builds are a separate app,
/// `com.mezzanine.mac.debug`, and never update themselves). The feed and DMGs live in the public
/// `ahamedzoha/mezzanine-releases` repo; updates are EdDSA-signed with the key in the owner's
/// Keychain. By default they download in the background and install when Mezzanine quits.
///
/// Never over a film: when an update would be shown while a film plays (full player or the
/// corner tile), it waits, and comes forward once the film closes (Settings ▸ Updates says so).
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// False in Debug builds.
    let isAvailable: Bool
    private(set) var canCheck = false
    private(set) var lastChecked: Date?
    /// The version found while a film played, shown when the player closes.
    private(set) var waitingVersion: String?

    var checksAutomatically = false {
        didSet { if controller?.updater.automaticallyChecksForUpdates != checksAutomatically { controller?.updater.automaticallyChecksForUpdates = checksAutomatically } }
    }
    var installsAutomatically = false {
        didSet { if controller?.updater.automaticallyDownloadsUpdates != installsAutomatically { controller?.updater.automaticallyDownloadsUpdates = installsAutomatically } }
    }

    /// True while a film plays, in the player or the corner tile (set by the app).
    @ObservationIgnored var isWatching: () -> Bool = { false }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []

    override init() {
        #if DEBUG
        isAvailable = false
        #else
        isAvailable = true
        #endif
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        watches = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastChecked = value }
            },
            // Sparkle can change these itself (its permission prompt); the switches follow.
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                let value = updater.automaticallyChecksForUpdates
                Task { @MainActor in if self?.checksAutomatically != value { self?.checksAutomatically = value } }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                let value = updater.automaticallyDownloadsUpdates
                Task { @MainActor in if self?.installsAutomatically != value { self?.installsAutomatically = value } }
            },
        ]
    }

    /// Mezzanine ▸ Check for Updates… and Settings ▸ Updates ▸ Check Now.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The film closed: bring forward an update that waited for it.
    func playerClosed() {
        guard waitingVersion != nil else { return }
        controller?.checkForUpdates(nil)
    }

    /// "0.2.0 (412)"
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Lets Sparkle ask before showing a scheduled update (below).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !isWatching() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { waitingVersion = handleShowingUpdate ? nil : version }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waitingVersion = nil }
    }
}
