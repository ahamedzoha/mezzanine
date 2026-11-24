import Foundation
import MezzanineKit
import MezzaninePlayback

/// One sound setup per output device, remembered by the device's id, and
/// applied to the player whenever the output changes.
///
/// A device starts from its kind's profile (`AudioOutputKind.defaultProfile`);
/// the owner can pick another kind for it (his 2.1 speakers look like plain
/// headphones to the Mac) or tune the profile itself in Settings ▸ Sound.
@MainActor
@Observable
final class SoundSettings {
    struct DeviceSetup: Codable, Equatable {
        var kind: AudioOutputKind
        var profile: AudioProfile
        var volumePercent: Double = 100
    }

    let route: AudioRouteMonitor
    private let player: MezzaninePlayer
    private var setups: [String: DeviceSetup]
    private static let storeKey = "soundSetups.v1"

    init(route: AudioRouteMonitor, player: MezzaninePlayer) {
        self.route = route
        self.player = player
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([String: DeviceSetup].self, from: data) {
            setups = saved
        } else {
            setups = [:]
        }
        observeRoute()
        apply()
    }

    /// The setup for the current output.
    var current: DeviceSetup {
        guard let device = route.device else { return DeviceSetup(kind: .other, profile: AudioOutputKind.other.defaultProfile) }
        return setups[device.profileKey] ?? DeviceSetup(kind: device.guessedKind, profile: device.guessedKind.defaultProfile)
    }

    var deviceName: String { route.device?.name ?? "No output" }

    // MARK: Changes

    /// Picks what this output is; resets its profile to that kind's starting point.
    func setKind(_ kind: AudioOutputKind) {
        update { $0.kind = kind; $0.profile = kind.defaultProfile }
    }

    func setProfile(_ profile: AudioProfile) { update { $0.profile = profile } }

    func setDialogue(_ db: Double) { update { $0.profile.dialogueGainDB = min(12, max(0, db)) } }
    func toggleDialogue() { update { $0.profile.dialogueGainDB = $0.profile.dialogueGainDB > 0 ? 0 : 6 } }
    func toggleNight() { update { $0.profile.nightMode.toggle() } }
    func setLoudness(_ lufs: Double?) { update { $0.profile.loudnessTargetLUFS = lufs } }

    /// Volume steps of 10 % up to 400 %; remembered per output.
    func stepVolume(_ delta: Double) {
        update { $0.volumePercent = min(VolumeLevel.maximumPercent, max(0, ($0.volumePercent + delta).rounded())) }
    }

    func setVolume(_ percent: Double) { update { $0.volumePercent = min(VolumeLevel.maximumPercent, max(0, percent)) } }

    private func update(_ change: (inout DeviceSetup) -> Void) {
        guard let device = route.device else { return }
        var setup = current
        change(&setup)
        setups[device.profileKey] = setup
        if let data = try? JSONEncoder().encode(setups) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        apply()
    }

    private func apply() {
        let setup = current
        AppLog.sound.info("\(setup.kind.rawValue, privacy: .public) \(Int(setup.volumePercent)) %")
        player.audioProfile = setup.profile
        player.volume = VolumeLevel(percent: setup.volumePercent)
    }

    private func observeRoute() {
        withObservationTracking { _ = route.device } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observeRoute()
            }
        }
    }
}

extension AudioOutputKind {
    var label: String {
        switch self {
        case .builtInSpeakers: return "Mac Speakers"
        case .headphones: return "Headphones"
        case .airPods: return "AirPods (spatial)"
        case .bluetooth: return "Bluetooth Speaker"
        case .hdmi: return "Receiver or Soundbar"
        case .speakers21: return "2.1 Speakers"
        case .usb: return "USB Audio"
        case .other: return "Stereo Speakers"
        }
    }

    /// One line on what the profile does, for menus and Settings.
    var summary: String {
        switch self {
        case .builtInSpeakers: return "Stereo, dialogue +6 dB, quiet films raised, night mode"
        case .headphones, .bluetooth, .usb, .other: return "Stereo, dialogue +3 dB, quiet films raised"
        case .speakers21: return "Stereo with the bass channel sent to your subwoofer, dialogue +3 dB"
        case .airPods: return "Surround kept, so AirPods spatialise it"
        case .hdmi: return "Untouched: 5.1 and Atmos go straight to the receiver"
        }
    }
}
