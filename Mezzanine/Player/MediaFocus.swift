import Foundation
import Observation

/// Coordinates who owns system Now Playing and media keys (`none | film | music`).
///
/// - When a video starts, music pauses and releases Now Playing / remote commands.
/// - When the video closes, clips/trailers (< 10 min) resume music automatically; films and
///   episodes leave music paused with `pausedMusicForTitle` so the user can resume with ⌥Space.
/// - When music starts, any active video pauses.
@MainActor
@Observable
final class MediaFocus {
    enum Owner: Equatable {
        case none
        case film
        case music
    }

    private(set) var owner: Owner = .none
    /// Set when a film or episode (>= 10 min) paused music and closed, so UI can offer "Paused for <title>".
    private(set) var pausedMusicForTitle: String?

    @ObservationIgnored private var musicWasPlayingBeforeVideo = false
    @ObservationIgnored private var pausedVideoDuration: TimeInterval = 0
    @ObservationIgnored private var pausedVideoTitle: String?

    @ObservationIgnored weak var music: MusicSession?
    @ObservationIgnored weak var playback: PlaybackCoordinator?

    func videoWillStart(title: String, duration: TimeInterval) {
        owner = .film
        pausedMusicForTitle = nil
        if let music, music.isPlaying {
            musicWasPlayingBeforeVideo = true
            pausedVideoDuration = duration
            pausedVideoTitle = title
            music.pauseForVideo()
        } else {
            musicWasPlayingBeforeVideo = false
            pausedVideoDuration = 0
            pausedVideoTitle = nil
            music?.deactivateNowPlaying()
        }
    }

    func videoDidClose() {
        guard owner == .film else { return }
        if musicWasPlayingBeforeVideo {
            musicWasPlayingBeforeVideo = false
            let wasShortClip = pausedVideoDuration > 0 && pausedVideoDuration < 600
            let title = pausedVideoTitle
            pausedVideoDuration = 0
            pausedVideoTitle = nil
            if wasShortClip {
                pausedMusicForTitle = nil
                owner = .music
                music?.resumeFromMediaFocus()
            } else {
                pausedMusicForTitle = title
                owner = (music?.isActive == true) ? .music : .none
                music?.reactivateNowPlaying()
            }
        } else {
            owner = (music?.isActive == true) ? .music : .none
            music?.reactivateNowPlaying()
        }
    }

    func musicWillStart() {
        pausedMusicForTitle = nil
        musicWasPlayingBeforeVideo = false
        pausedVideoDuration = 0
        pausedVideoTitle = nil
        if owner == .film || playback?.isVideoActive == true {
            playback?.pauseForMusic()
        }
        owner = .music
    }

    func musicDidStop() {
        if owner == .music {
            owner = (playback?.isVideoActive == true) ? .film : .none
        }
    }
}
