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
}
