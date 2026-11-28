import Foundation

/// Keeps the Mac awake while media plays:
/// - `.film`: holds display + system sleep (`idleDisplaySleepDisabled`) so the screen never dims mid-film.
/// - `.music`: holds only idle system sleep (`idleSystemSleepDisabled`) so the display can dim/sleep while music keeps playing.
/// - `.none`: lets the Mac sleep as usual.
@MainActor
final class KeepAwake {
    enum Mode: Equatable {
        case none
        case film
        case music
    }

    private var activity: NSObjectProtocol?
    private(set) var mode: Mode = .none

    func update(mode nextMode: Mode) {
        guard nextMode != mode else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        mode = nextMode
        switch nextMode {
        case .none:
            break
        case .film:
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Playing a video"
            )
        case .music:
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Playing music"
            )
        }
    }

    func update(playing: Bool) {
        update(mode: playing ? .film : .none)
    }

    var isHolding: Bool { activity != nil }
}
