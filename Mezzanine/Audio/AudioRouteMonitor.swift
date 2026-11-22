import Foundation
import CoreAudio
import MezzanineKit

/// The Mac's current default output device, kept live through CoreAudio
/// listeners (device switches, headphones plugged into the jack).
struct OutputDevice: Equatable, Sendable {
    var uid: String
    var name: String
    var transport: UInt32
    /// Built-in device data source: 'ispk' internal speakers, 'hdpn' headphones.
    var dataSource: UInt32?
    var channels: Int

    /// What kind of output this looks like, for its starting sound profile.
    var guessedKind: AudioOutputKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == fourCC("hdpn") ? .headphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return name.localizedCaseInsensitiveContains("airpods") || name.localizedCaseInsensitiveContains("beats") ? .airPods : .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            // A receiver or soundbar exposes more than two channels; a monitor's speakers don't.
            return channels > 2 ? .hdmi : .other
        case kAudioDeviceTransportTypeUSB:
            return .usb
        default:
            return .other
        }
    }

    /// Stable key for remembering this output's profile (built-in speakers and the
    /// headphone jack share one device, so the data source is part of it).
    var profileKey: String {
        if transport == kAudioDeviceTransportTypeBuiltIn, let dataSource { return "\(uid)#\(dataSource)" }
        return uid
    }
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

@MainActor
@Observable
final class AudioRouteMonitor {
    private(set) var device: OutputDevice?

    @ObservationIgnored private var listenedDevice: AudioDeviceID = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "mezzanine.audio-route")

    init() {
        refresh()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, Self.listener(self))
    }

    /// CoreAudio calls listeners on `queue`, never the main thread. A closure written
    /// inside this MainActor class inherits MainActor isolation, and Swift 6 traps when
    /// CoreAudio runs it off the main thread (crashed 0.3.2 when the output device
    /// changed with the app in the background). Built here, the block is nonisolated
    /// and only hops to the main actor.
    private nonisolated static func listener(_ monitor: AudioRouteMonitor) -> AudioObjectPropertyListenerBlock {
        { [weak monitor] _, _ in
            Task { @MainActor in monitor?.refresh() }
        }
    }

    func refresh() {
        guard let id = Self.defaultOutputDevice() else { device = nil; return }
        if id != listenedDevice {
            listenedDevice = id
            // Headphones plugged into the jack change the built-in device's data source.
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &address, queue, Self.listener(self))
        }
        let next = OutputDevice(uid: Self.string(id, kAudioDevicePropertyDeviceUID) ?? "unknown",
                                name: Self.string(id, kAudioObjectPropertyName) ?? "Output",
                                transport: Self.uint32(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0,
                                dataSource: Self.uint32(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
                                channels: Self.outputChannels(id))
        if next != device { device = next }
    }

    // MARK: CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 2 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 2 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
