import AppKit
import SwiftUI
import Observation

/// Something a single key does in the player. Every one is rebindable in
/// Settings ▸ Shortcuts and has a Playback menu item showing its key.
enum PlayerKey: String, CaseIterable, Identifiable, Codable {
    case playPause, back10, forward10, back60, forward60, previousChapter, nextChapter
    case previousFrame, nextFrame, slower, faster
    case skipMarker, nextEpisode, previousEpisode
    case volumeUp, volumeDown, mute, dialogueBoost, nightMode
    case cycleAudio, cycleSubtitles, subtitleOptions, findSubtitles, subtitlesEarlier, subtitlesLater
    case generateSubtitles, translateSubtitles, matchSubtitleTiming
    case fullScreen, pictureInPicture, options, stats, pictureMode, miniPlayer
    case whatDidTheySay, goToTime, sleepTimer, queue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playPause: "Play / pause"
        case .back10: "Back 10 seconds"
        case .forward10: "Forward 10 seconds"
        case .back60: "Back 1 minute"
        case .forward60: "Forward 1 minute"
        case .previousChapter: "Previous chapter"
        case .nextChapter: "Next chapter"
        case .previousFrame: "Previous frame"
        case .nextFrame: "Next frame"
        case .slower: "Slower"
        case .faster: "Faster"
        case .skipMarker: "Skip intro or credits"
        case .nextEpisode: "Next episode"
        case .previousEpisode: "Previous episode"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .dialogueBoost: "Dialogue boost"
        case .nightMode: "Night mode"
        case .cycleAudio: "Next audio track"
        case .cycleSubtitles: "Next subtitle track"
        case .subtitleOptions: "Subtitle options"
        case .findSubtitles: "Find subtitles"
        case .generateSubtitles: "Generate subtitles from speech"
        case .translateSubtitles: "Translate subtitles"
        case .matchSubtitleTiming: "Match subtitle timing to speech"
        case .subtitlesEarlier: "Subtitles earlier (0.1 s)"
        case .subtitlesLater: "Subtitles later (0.1 s)"
        case .fullScreen: "Full screen"
        case .pictureInPicture: "Picture in Picture"
        case .options: "Audio, subtitles, sound and speed"
        case .stats: "Playback info"
        case .pictureMode: "Picture: fit, fill or zoom"
        case .miniPlayer: "Mini player (keep browsing)"
        case .whatDidTheySay: "What did they say? (back with subtitles)"
        case .goToTime: "Go to a time"
        case .sleepTimer: "Sleep timer"
        case .queue: "Queue"
        }
    }

    /// Title Case, for menu items.
    var menuTitle: String {
        switch self {
        case .playPause: "Play/Pause"
        case .back10: "Back 10 Seconds"
        case .forward10: "Forward 10 Seconds"
        case .back60: "Back 1 Minute"
        case .forward60: "Forward 1 Minute"
        case .previousChapter: "Previous Chapter"
        case .nextChapter: "Next Chapter"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .slower: "Slower"
        case .faster: "Faster"
        case .skipMarker: "Skip Intro or Credits"
        case .nextEpisode: "Next Episode"
        case .previousEpisode: "Previous Episode"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        case .dialogueBoost: "Dialogue Boost"
        case .nightMode: "Night Mode"
        case .cycleAudio: "Next Audio Track"
        case .cycleSubtitles: "Next Subtitle Track"
        case .subtitleOptions: "Subtitle Options…"
        case .findSubtitles: "Find Subtitles…"
        case .generateSubtitles: "Generate Subtitles from Speech"
        case .translateSubtitles: "Translate Subtitles"
        case .matchSubtitleTiming: "Match Subtitle Timing to Speech"
        case .subtitlesEarlier: "Subtitles Earlier"
        case .subtitlesLater: "Subtitles Later"
        case .fullScreen: "Enter Full Screen"
        case .pictureInPicture: "Picture in Picture"
        case .options: "Audio, Subtitles and Sound…"
        case .stats: "Playback Info"
        case .pictureMode: "Next Picture Size"
        case .miniPlayer: "Mini Player"
        case .whatDidTheySay: "What Did They Say?"
        case .goToTime: "Go to Time…"
        case .sleepTimer: "Sleep Timer…"
        case .queue: "Queue…"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case playback = "Playback", episodes = "Episodes", sound = "Sound", subtitles = "Audio and subtitles", view = "View"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .playPause, .back10, .forward10, .back60, .forward60, .previousChapter, .nextChapter,
             .previousFrame, .nextFrame, .slower, .faster, .goToTime, .sleepTimer: .playback
        case .skipMarker, .nextEpisode, .previousEpisode, .queue: .episodes
        case .volumeUp, .volumeDown, .mute, .dialogueBoost, .nightMode: .sound
        case .cycleAudio, .cycleSubtitles, .subtitleOptions, .findSubtitles, .subtitlesEarlier, .subtitlesLater,
             .generateSubtitles, .translateSubtitles, .matchSubtitleTiming, .whatDidTheySay: .subtitles
        case .fullScreen, .pictureInPicture, .options, .stats, .pictureMode, .miniPlayer: .view
        }
    }

    var defaultBindings: [KeyBinding] {
        switch self {
        case .playPause: [.code(KeyBinding.space), .char("k")]
        case .back10: [.code(KeyBinding.left), .char("j")]
        case .forward10: [.code(KeyBinding.right), .char("l")]
        case .back60: [.code(KeyBinding.left, shift: true)]
        case .forward60: [.code(KeyBinding.right, shift: true)]
        case .previousChapter: [.code(KeyBinding.left, option: true), .code(KeyBinding.pageUp)]
        case .nextChapter: [.code(KeyBinding.right, option: true), .code(KeyBinding.pageDown)]
        case .previousFrame: [.char(",")]
        case .nextFrame: [.char(".")]
        case .slower: [.char("[")]
        case .faster: [.char("]")]
        case .skipMarker: [.char("s")]
        case .nextEpisode: [.char("n")]
        case .previousEpisode: [.char("N")]
        case .volumeUp: [.code(KeyBinding.up)]
        case .volumeDown: [.code(KeyBinding.down)]
        case .mute: [.char("m")]
        case .dialogueBoost: [.char("d")]
        case .nightMode: [.char("n", option: true)]
        case .cycleAudio: [.char("a")]
        case .cycleSubtitles: [.char("c")]
        case .subtitleOptions: [.char("C")]
        case .findSubtitles: [.char("f", option: true)]
        case .generateSubtitles: [.char("g", option: true)]
        case .translateSubtitles: [.char("t", option: true)]
        case .matchSubtitleTiming: [.char("h", option: true)]
        case .subtitlesEarlier: [.char("g")]
        case .subtitlesLater: [.char("h")]
        case .fullScreen: [.char("f")]
        case .pictureInPicture: [.char("p", option: true)]
        case .options: [.char("o")]
        case .stats: [.char("i")]
        case .pictureMode: [.char("z")]
        case .miniPlayer: [.char("m", option: true)]
        case .whatDidTheySay: [.char("w")]
        case .goToTime: [.char("t")]
        case .sleepTimer: [.char("s", option: true)]
        case .queue: [.char("q")]
        }
    }
}

/// One key as the player matches it: special keys (arrows, Space, Page Up…)
/// by key code with ⇧/⌥, everything else by the character it types
/// (layout-aware; ⇧ is part of the character, "N" or "<") with ⌥. ⌘ and ⌃
/// keys belong to the menus and never reach the player.
struct KeyBinding: Codable, Hashable, Sendable {
    var keyCode: UInt16?
    var character: String?
    var shift = false
    var option = false
    var command = false

    enum CodingKeys: String, CodingKey { case keyCode, character, shift, option, command }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        character = try c.decodeIfPresent(String.self, forKey: .character)
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        option = try c.decodeIfPresent(Bool.self, forKey: .option) ?? false
        command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
    }

    static func code(_ code: UInt16, shift: Bool = false, option: Bool = false, command: Bool = false) -> KeyBinding {
        KeyBinding(keyCode: code, character: nil, shift: shift, option: option, command: command)
    }

    static func char(_ character: String, option: Bool = false, command: Bool = false) -> KeyBinding {
        KeyBinding(keyCode: nil, character: character, shift: false, option: option, command: command)
    }

    static let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let pageUp: UInt16 = 116, pageDown: UInt16 = 121, home: UInt16 = 115, end: UInt16 = 119
    static let escape: UInt16 = 53, tab: UInt16 = 48, returnKey: UInt16 = 36, enter: UInt16 = 76

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Keys matched by code, with how they're written.
    static let specialKeys: [UInt16: String] = functionKeys.merging([
        space: "Space", left: "←", right: "→", up: "↑", down: "↓",
        pageUp: "Page Up", pageDown: "Page Down", home: "Home", end: "End",
    ]) { a, _ in a }

    /// The binding a key press is, or nil for keys the player never rebinds
    /// (⌘/⌃ combinations, Esc, Tab, Return).
    init?(_ event: NSEvent, allowingCommand: Bool = false) {
        let mods = event.modifierFlags
        if (mods.contains(.command) && !allowingCommand) || mods.contains(.control) { return nil }
        let shift = mods.contains(.shift), option = mods.contains(.option), command = mods.contains(.command)
        if [Self.escape, Self.tab, Self.returnKey, Self.enter].contains(event.keyCode) { return nil }
        if Self.specialKeys[event.keyCode] != nil {
            self = .code(event.keyCode, shift: shift, option: option, command: command)
            return
        }
        var character = event.charactersIgnoringModifiers ?? ""
        // Control characters and the private-use codes AppKit gives keys with no glyph.
        guard !character.isEmpty, character.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }) else { return nil }
        // Caps Lock types capitals without ⇧: still the plain key.
        if !shift { character = character.lowercased() }
        self = .char(character, option: option, command: command)
    }

    private init(keyCode: UInt16?, character: String?, shift: Bool, option: Bool, command: Bool = false) {
        self.keyCode = keyCode
        self.character = character
        self.shift = shift
        self.option = option
        self.command = command
    }

    /// As shown in Settings and help: "⌥←", "⇧N", "⌥⌘S", "Page Down".
    var display: String {
        var prefix = option ? "⌥" : ""
        if let keyCode {
            if shift { prefix += "⇧" }
            if command { prefix += "⌘" }
            return prefix + (Self.specialKeys[keyCode] ?? "Key \(keyCode)")
        }
        guard let character else { return "?" }
        if character != character.lowercased() { prefix += "⇧" }
        if command { prefix += "⌘" }
        return prefix + character.uppercased()
    }

    /// The same key as a menu key equivalent, so the Playback / Controls menus show it.
    var menuShortcut: KeyboardShortcut? {
        var modifiers: EventModifiers = []
        if option { modifiers.insert(.option) }
        if command { modifiers.insert(.command) }
        if let keyCode {
            if shift { modifiers.insert(.shift) }
            let key: KeyEquivalent
            switch keyCode {
            case Self.space: key = .space
            case Self.left: key = .leftArrow
            case Self.right: key = .rightArrow
            case Self.up: key = .upArrow
            case Self.down: key = .downArrow
            case Self.pageUp: key = .pageUp
            case Self.pageDown: key = .pageDown
            case Self.home: key = .home
            case Self.end: key = .end
            default: return nil
            }
            return KeyboardShortcut(key, modifiers: modifiers)
        }
        guard let character, character.count == 1 else { return nil }
        if character != character.lowercased() { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(Character(character.lowercased())), modifiers: modifiers)
    }

    /// Keys with fixed meanings: 0–9 jump through the film.
    var reservation: String? {
        guard keyCode == nil, !option, let character, let digit = Int(character), (0...9).contains(digit) else { return nil }
        return "0–9 jump through the film"
    }
}

/// The player's keys. Only changes from the defaults are stored.
@MainActor
@Observable
final class PlayerShortcuts {
    static let shared = PlayerShortcuts()

    private(set) var overrides: [PlayerKey: [KeyBinding]] = [:]
    @ObservationIgnored private var lookup: [KeyBinding: PlayerKey] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "playerShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) {
            for (key, bindings) in stored {
                if let action = PlayerKey(rawValue: key) { overrides[action] = bindings }
            }
        }
        rebuild()
    }

    func bindings(_ action: PlayerKey) -> [KeyBinding] {
        overrides[action] ?? action.defaultBindings
    }

    func action(for event: NSEvent) -> PlayerKey? {
        guard let binding = KeyBinding(event) else { return nil }
        if let action = lookup[binding] { return action }
        // ⇧ with a special key nobody bound with ⇧: the plain key.
        if binding.keyCode != nil, binding.shift {
            var plain = binding
            plain.shift = false
            return lookup[plain]
        }
        return nil
    }

    /// The first key, for the menu item.
    func menuShortcut(_ action: PlayerKey) -> KeyboardShortcut? {
        bindings(action).lazy.compactMap(\.menuShortcut).first
    }

    /// "Space or K"; "None" when unbound.
    func display(_ action: PlayerKey, separator: String = " or ") -> String {
        let keys = bindings(action)
        return keys.isEmpty ? "None" : keys.map(\.display).joined(separator: separator)
    }

    /// For tooltips: "Picture in Picture (⌥P)"; the title alone when unbound.
    func help(_ title: String, _ action: PlayerKey) -> String {
        let keys = bindings(action)
        return keys.isEmpty ? title : "\(title) (\(keys.map(\.display).joined(separator: " or ")))"
    }

    var isCustomized: Bool { !overrides.isEmpty }
    func isCustomized(_ action: PlayerKey) -> Bool { overrides[action] != nil }

    /// Puts `binding` on `action` (replacing `old`, or added). A key another
    /// action had moves here; returns that action so the change can be said.
    @discardableResult
    func assign(_ binding: KeyBinding, to action: PlayerKey, replacing old: KeyBinding? = nil) -> PlayerKey? {
        var previousOwner: PlayerKey?
        if let owner = lookup[binding], owner != action {
            previousOwner = owner
            set(owner, bindings(owner).filter { $0 != binding })
        }
        var keys = bindings(action)
        if let old, let index = keys.firstIndex(of: old) {
            keys[index] = binding
        } else if !keys.contains(binding) {
            keys.append(binding)
        }
        var seen = Set<KeyBinding>()
        set(action, keys.filter { seen.insert($0).inserted })
        return previousOwner
    }

    func remove(_ binding: KeyBinding, from action: PlayerKey) {
        set(action, bindings(action).filter { $0 != binding })
    }

    /// Back to the default keys. A default another action now uses moves back
    /// too; returns those actions so the change can be said.
    @discardableResult
    func restore(_ action: PlayerKey) -> [PlayerKey] {
        var losers: [PlayerKey] = []
        for binding in action.defaultBindings {
            if let owner = lookup[binding], owner != action {
                losers.append(owner)
                overrides[owner] = bindings(owner).filter { $0 != binding }
                if overrides[owner] == owner.defaultBindings { overrides[owner] = nil }
            }
        }
        overrides[action] = nil
        save()
        return losers
    }

    func restoreAll() {
        overrides = [:]
        save()
    }

    private func set(_ action: PlayerKey, _ keys: [KeyBinding]) {
        overrides[action] = keys == action.defaultBindings ? nil : keys
        save()
    }

    private func save() {
        rebuild()
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if stored.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func rebuild() {
        var table: [KeyBinding: PlayerKey] = [:]
        for action in PlayerKey.allCases {
            for binding in bindings(action) where table[binding] == nil { table[binding] = action }
        }
        lookup = table
    }
}

/// Routes single keys to the player while it's open.
///
/// A window event monitor, ahead of the menus: the Playback menu shows each key as its
/// key equivalent, and without this a letter typed into a field (Find Subtitles) would
/// fire the menu item instead. While the player is open, plain keys go to whatever is
/// typing or focused first, then to the player; the menus see only ⌘/⌃ keys.
@MainActor
final class PlayerKeyRouter {
    static let shared = PlayerKeyRouter()

    /// Returns whether the key was used. Set by the player stage while it's on screen.
    typealias Handler = (NSEvent, PlayerKey?) -> Bool

    private var monitor: Any?
    private weak var window: NSWindow?
    private var handler: Handler?

    func attach(window: NSWindow?, handler: @escaping Handler) {
        self.window = window
        self.handler = handler
        install()
    }

    func detach() {
        handler = nil
        window = nil
    }

    private func install() {
        guard monitor == nil else { return }
        // Local monitors run on the main thread; the event never leaves it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { PlayerKeyRouter.shared.route(event) }
            return consumed ? nil : event
        }
    }

    /// - Returns: whether the event was consumed here.
    private func route(_ event: NSEvent) -> Bool {
        guard let handler, let eventWindow = event.window else { return false }
        let mods = event.modifierFlags
        if mods.contains(.command) || mods.contains(.control) { return false }
        // A save panel answers its own Return and Esc.
        if eventWindow is NSSavePanel { return false }

        // Typing (any window): the field gets every plain key, never a menu equivalent.
        if let text = eventWindow.firstResponder as? NSText {
            eventWindow.sendEvent(event)
            // Esc in a field: after the field has it, leave the field so the keys play again.
            if event.keyCode == KeyBinding.escape {
                DispatchQueue.main.async {
                    if eventWindow.firstResponder === text { eventWindow.makeFirstResponder(nil) }
                }
            }
            return true
        }
        guard eventWindow === window, eventWindow.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        if handler(event, PlayerShortcuts.shared.action(for: event)) { return true }
        // Not the player's: deliver to the focused control directly (a focused button's
        // Space), bypassing menu equivalents.
        eventWindow.sendEvent(event)
        return true
    }
}
