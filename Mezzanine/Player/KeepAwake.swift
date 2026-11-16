import Foundation

/// Keeps the display (and the Mac) awake while a video plays: the full player or the corner
/// tile. Paused, closed or casting to a TV, the Mac dims and sleeps as usual. AetherEngine only
/// asks for this on its software route (`AVSampleBufferDisplayLayer`); on the native AVPlayer
/// route nothing did, so the screen dimmed mid-film without a key press.
@MainActor
final class KeepAwake {
    private var activity: NSObjectProtocol?

    func update(playing: Bool) {
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Playing a video")
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    var isHolding: Bool { activity != nil }
}
