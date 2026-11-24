import Foundation

/// How Mezzanine shapes a title's audio for one output device. Engine
/// agnostic: the playback adapter maps it onto the engine's own shaping.
///
/// The fix for "5.1 plays too quietly on stereo": a 5.1 → 2.0 fold drops the
/// centre (dialogue) and surrounds by 3 dB and the LFE entirely, and a
/// normalised fold costs another ~7.6 dB. Mezzanine folds unnormalised into a
/// limiter, lifts the centre, and optionally raises quiet masters to a
/// loudness target, so a film plays about as loud as stereo TV.
public struct AudioProfile: Codable, Sendable, Equatable, Hashable {
    /// Fold to at most this many channels (nil = keep the source's layout).
    public var maxChannels: Int?
    /// LFE level mixed into a fold that would otherwise drop it (2.1 systems), dB.
    public var lfeMixDB: Double?
    /// Raise the centre channel / extracted dialogue, 0…12 dB.
    public var dialogueGainDB: Double
    /// Lift quiet masters to this programme loudness (-36…-12 LUFS), nil = off.
    public var loudnessTargetLUFS: Double?
    /// Compress dynamics (quiet scenes up, loud scenes down).
    public var nightMode: Bool

    public init(maxChannels: Int? = nil, lfeMixDB: Double? = nil, dialogueGainDB: Double = 0,
                loudnessTargetLUFS: Double? = nil, nightMode: Bool = false) {
        self.maxChannels = maxChannels
        self.lfeMixDB = lfeMixDB
        self.dialogueGainDB = dialogueGainDB
        self.loudnessTargetLUFS = loudnessTargetLUFS
        self.nightMode = nightMode
    }

    /// Nothing shaped: every bitstream (Atmos, 5.1) passes through untouched.
    public static let passthrough = AudioProfile()

    public var isPassthrough: Bool {
        maxChannels == nil && dialogueGainDB == 0 && loudnessTargetLUFS == nil && !nightMode
    }
}

/// The kind of output device, which picks the starting profile.
public enum AudioOutputKind: String, Codable, Sendable, CaseIterable {
    case builtInSpeakers
    case headphones
    case airPods
    case bluetooth
    case hdmi
    case speakers21
    case usb
    case other

    /// Starting profile for a device of this kind. The user tunes each device
    /// once; Mezzanine remembers it by the device's UID.
    public var defaultProfile: AudioProfile {
        switch self {
        case .builtInSpeakers:
            // Small speakers: fold, lift dialogue, raise quiet films, tame peaks.
            return AudioProfile(maxChannels: 2, dialogueGainDB: 6, loudnessTargetLUFS: -16, nightMode: true)
        case .headphones, .bluetooth, .usb, .other:
            return AudioProfile(maxChannels: 2, dialogueGainDB: 3, loudnessTargetLUFS: -20)
        case .speakers21:
            // Keep the .1: fold the LFE into left/right so the sub hears it.
            return AudioProfile(maxChannels: 2, lfeMixDB: 0, dialogueGainDB: 3, loudnessTargetLUFS: -20)
        case .airPods:
            // Keep multichannel so AVFoundation spatialises it.
            return .passthrough
        case .hdmi:
            // A receiver or soundbar decodes 5.1 / Atmos itself.
            return .passthrough
        }
    }
}

/// Volume as the user sees it: 0…400 %. Up to 100 % is the engine's own
/// volume; above that is gain in front of the limiter.
public struct VolumeLevel: Sendable, Equatable {
    public static let maximumPercent: Double = 400

    public var percent: Double

    public init(percent: Double) {
        self.percent = min(max(percent, 0), Self.maximumPercent)
    }

    /// 0…1 for the player's own volume.
    public var linearVolume: Double { min(percent, 100) / 100 }

    /// Gain added above 100 %, in dB (400 % ≈ +12 dB).
    public var boostDB: Double {
        guard percent > 100 else { return 0 }
        return 20 * log10(percent / 100)
    }

    public var isBoosted: Bool { percent > 100 }

    // MARK: Built-in boost

    /// Gain above 100 % sits in front of the engine's limiter, and changing it rebuilds the
    /// playing session (the picture holds for about a second). So it is built in steps
    /// (100, 141, 200, 283, 400 %) and the player's own volume takes back the rest.
    public static let boostStepDB = 10 * log10(2.0)

    /// The gain to build into the audio for this level: the level rounded up to a step, or
    /// `current` (what is built in now) while it covers the level with at most a step to spare.
    /// An untouched (`passthrough`) profile goes back to no gain at 100 % and below, so Atmos
    /// and 5.1 pass through again.
    public func builtInBoostDB(current: Double, passthrough: Bool) -> Double {
        let wanted = boostDB
        let slack = 1e-6
        if wanted == 0, passthrough { return 0 }
        if current >= wanted - slack, current - wanted <= Self.boostStepDB + slack { return current }
        return ((wanted - slack) / Self.boostStepDB).rounded(.up) * Self.boostStepDB
    }

    /// 0…1 for the player's own volume when `builtIn` dB of gain is already in the audio.
    public func playerVolume(builtInBoostDB builtIn: Double) -> Double {
        min(1, linearVolume * pow(10, (boostDB - builtIn) / 20))
    }
}
