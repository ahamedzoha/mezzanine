import Foundation
import SwiftUI

/// Actions in the global Controls menu for music playback.
enum MusicKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case shuffle
    case repeatMode
    case rate5, rate4, rate3, rate2, rate1, rate0

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .volumeUp: "Increase Volume"
        case .volumeDown: "Decrease Volume"
        case .shuffle: "Shuffle"
        case .repeatMode: "Repeat"
        case .rate5: "5 Stars"
        case .rate4: "4 Stars"
        case .rate3: "3 Stars"
        case .rate2: "2 Stars"
        case .rate1: "1 Star"
        case .rate0: "Clear Rating"
        }
    }

    var defaultBindings: [KeyBinding] {
        switch self {
        case .playPause: [.code(KeyBinding.space, option: true)]
        case .nextTrack: [.code(KeyBinding.right, command: true)]
        case .previousTrack: [.code(KeyBinding.left, command: true)]
        case .volumeUp: [.code(KeyBinding.up, option: true, command: true)]
        case .volumeDown: [.code(KeyBinding.down, option: true, command: true)]
        case .shuffle: [.char("s", option: true, command: true)]
        case .repeatMode: [.char("r", option: true, command: true)]
        case .rate5: [.char("5", option: true, command: true)]
        case .rate4: [.char("4", option: true, command: true)]
        case .rate3: [.char("3", option: true, command: true)]
        case .rate2: [.char("2", option: true, command: true)]
        case .rate1: [.char("1", option: true, command: true)]
        case .rate0: [.char("0", option: true, command: true)]
        }
    }
}

/// Global music shortcuts (Controls menu). Only overrides from defaults are stored.
@MainActor
@Observable
final class MusicShortcuts {
    static let shared = MusicShortcuts()

    private(set) var overrides: [MusicKey: [KeyBinding]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "musicShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) {
            for (key, bindings) in stored {
                if let action = MusicKey(rawValue: key) { overrides[action] = bindings }
            }
        }
    }

    func bindings(_ action: MusicKey) -> [KeyBinding] {
        overrides[action] ?? action.defaultBindings
    }

    func menuShortcut(_ action: MusicKey) -> KeyboardShortcut? {
        bindings(action).first?.menuShortcut
    }

    func set(_ bindings: [KeyBinding], for action: MusicKey) {
        if bindings == action.defaultBindings {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = bindings
        }
        let encoded = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func resetAll() {
        overrides.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}
