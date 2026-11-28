import Foundation
import SwiftUI

/// Actions in the global Controls menu for music playback.
enum MusicKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
    case skipBack, skipForward
    case volumeUp
    case volumeDown
    case shuffle
    case repeatMode
    case rate5, rate4, rate3, rate2, rate1, rate0
    // The Item menu on Music pages, and Now Playing.
    case nowPlaying, playNext, playLater, shufflePlay, goToArtist, goToAlbum

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .skipBack: "Skip Back 10 Seconds"
        case .skipForward: "Skip Forward 10 Seconds"
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
        case .nowPlaying: "Now Playing"
        case .playNext: "Play Next"
        case .playLater: "Play Later"
        case .shufflePlay: "Play Shuffled"
        case .goToArtist: "Go to Artist"
        case .goToAlbum: "Go to Album"
        }
    }

    /// How Settings and the shortcuts sheet sort them.
    enum Group: String, CaseIterable, Identifiable {
        case playback = "Playback", item = "Songs and albums", rating = "Rating"
        var id: String { rawValue }
        var title: String { "Music: \(rawValue)" }
    }

    var group: Group {
        switch self {
        case .playPause, .nextTrack, .previousTrack, .skipBack, .skipForward, .volumeUp, .volumeDown, .shuffle, .repeatMode, .nowPlaying: .playback
        case .rate5, .rate4, .rate3, .rate2, .rate1, .rate0: .rating
        case .playNext, .playLater, .shufflePlay, .goToArtist, .goToAlbum: .item
        }
    }

    var defaultBindings: [KeyBinding] {
        switch self {
        case .playPause: [.code(KeyBinding.space, option: true)]
        case .nextTrack: [.code(KeyBinding.right, command: true)]
        case .previousTrack: [.code(KeyBinding.left, command: true)]
        case .skipBack: [.code(KeyBinding.left, option: true, command: true)]
        case .skipForward: [.code(KeyBinding.right, option: true, command: true)]
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
        // Free of the fixed menu keys (⌘K ⌘F ⌘E ⌘N ⇧⌘R ⇧⌘D ⇧⌘S ⌥⌘A/B/L/P and the ⌃⌘ Go keys).
        case .nowPlaying: [.char("l", command: true)]
        case .playNext: [.char("N", command: true)]
        case .playLater: [.char("L", command: true)]
        case .shufflePlay: [.char("S", option: true, command: true)]
        case .goToArtist: [.char("A", command: true)]
        case .goToAlbum: [.char("B", command: true)]
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
        #if DEBUG
        // The defaults must clear the app's fixed menu keys and each other.
        var seen = Set<KeyBinding>()
        for key in MusicKey.allCases {
            for binding in key.defaultBindings {
                assert(MusicKey.reservation(binding) == nil, "\(key) default clashes: \(MusicKey.reservation(binding) ?? "")")
                assert(seen.insert(binding).inserted, "\(key) default is used twice")
            }
        }
        #endif
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

    var isCustomized: Bool { !overrides.isEmpty }
    func isCustomized(_ action: MusicKey) -> Bool { overrides[action] != nil }

    /// "⌥⌘←" or "None".
    func display(_ action: MusicKey, separator: String = " or ") -> String {
        let keys = bindings(action)
        return keys.isEmpty ? "None" : keys.map(\.display).joined(separator: separator)
    }

    /// The action that already uses this key.
    func owner(of binding: KeyBinding) -> MusicKey? {
        MusicKey.allCases.first { bindings($0).contains(binding) }
    }

    /// Puts `binding` on `action` (replacing `old`, or added). A key another action had moves here;
    /// returns that action so the change can be said.
    @discardableResult
    func assign(_ binding: KeyBinding, to action: MusicKey, replacing old: KeyBinding? = nil) -> MusicKey? {
        var previous: MusicKey?
        if let owner = owner(of: binding), owner != action {
            previous = owner
            set(bindings(owner).filter { $0 != binding }, for: owner)
        }
        var keys = bindings(action)
        if let old, let index = keys.firstIndex(of: old) { keys[index] = binding }
        else if !keys.contains(binding) { keys.append(binding) }
        var seen = Set<KeyBinding>()
        set(keys.filter { seen.insert($0).inserted }, for: action)
        return previous
    }

    func remove(_ binding: KeyBinding, from action: MusicKey) {
        set(bindings(action).filter { $0 != binding }, for: action)
    }

    /// Back to the default; a default another action now uses moves back too. Returns the losers.
    @discardableResult
    func restore(_ action: MusicKey) -> [MusicKey] {
        var losers: [MusicKey] = []
        for binding in action.defaultBindings {
            if let owner = owner(of: binding), owner != action {
                losers.append(owner)
                set(bindings(owner).filter { $0 != binding }, for: owner)
            }
        }
        set(action.defaultBindings, for: action)
        return losers
    }

    func resetAll() {
        overrides.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}

extension MusicKey {
    /// Menu keys the app owns (they can't be given to a music action).
    static let fixedMenuKeys: [(keys: String, binding: KeyBinding)] = [
        ("⌘K", .char("k", command: true)), ("⌘F", .char("f", command: true)), ("⌘E", .char("e", command: true)),
        ("⌘N", .char("n", command: true)), ("⌘I", .char("i", command: true)), ("⌘W", .char("w", command: true)),
        ("⌘Q", .char("q", command: true)), ("⌘,", .char(",", command: true)), ("⌘/", .char("/", command: true)),
        ("⌘[", .char("[", command: true)), ("⌘]", .char("]", command: true)), ("⌘=", .char("=", command: true)),
        ("⌘−", .char("-", command: true)), ("⌘↩", .code(KeyBinding.returnKey, command: true)),
        ("⌘↑", .code(KeyBinding.up, command: true)), ("⇧⌘R", .char("R", command: true)), ("⇧⌘D", .char("D", command: true)),
        ("⇧⌘S", .char("S", command: true)), ("⌥⌘A", .char("a", option: true, command: true)),
        ("⌥⌘B", .char("b", option: true, command: true)), ("⌥⌘L", .char("l", option: true, command: true)),
        ("⌥⌘P", .char("p", option: true, command: true)),
    ] + (1...9).map { ("⌘\($0)", KeyBinding.char(String($0), command: true)) }

    /// Why a key can't go on a music action, or nil. A music key needs ⌘ or ⌥ (a bare letter
    /// would fire while typing in a field) and mustn't take a fixed menu key.
    static func reservation(_ binding: KeyBinding) -> String? {
        guard binding.command || binding.option else { return "Add ⌘ or ⌥ so it doesn’t fire while you type" }
        if let fixed = fixedMenuKeys.first(where: { $0.binding == binding }) { return "\(fixed.keys) is a fixed menu key" }
        return nil
    }
}
