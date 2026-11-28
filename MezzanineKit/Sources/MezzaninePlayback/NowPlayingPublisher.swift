import Foundation
import AppKit
import MediaPlayer
import MezzanineKit

/// Owns the system Now Playing card and media keys when music has focus.
///
/// Both `MusicEngine` and `EngineDeck` leave system Now Playing untouched so this publisher
/// is the single source of truth for audio metadata, queue position, artwork and remote
/// commands, and can hand control cleanly back to `MezzaninePlayer` when a film starts.
@MainActor
public final class NowPlayingPublisher {
    public struct Handlers {
        public var play: @MainActor () -> Void
        public var pause: @MainActor () -> Void
        public var togglePlayPause: @MainActor () -> Void
        public var nextTrack: @MainActor () -> Void
        public var previousTrack: @MainActor () -> Void
        public var seek: @MainActor (TimeInterval) -> Void

        public init(
            play: @escaping @MainActor () -> Void = {},
            pause: @escaping @MainActor () -> Void = {},
            togglePlayPause: @escaping @MainActor () -> Void = {},
            nextTrack: @escaping @MainActor () -> Void = {},
            previousTrack: @escaping @MainActor () -> Void = {},
            seek: @escaping @MainActor (TimeInterval) -> Void = { _ in }
        ) {
            self.play = play
            self.pause = pause
            self.togglePlayPause = togglePlayPause
            self.nextTrack = nextTrack
            self.previousTrack = previousTrack
            self.seek = seek
        }
    }

    private var handlers = Handlers()
    private var isActive = false
    private var tokens: [(MPRemoteCommand, Any)] = []

    public init() {}

    /// Registers media-key and Control Centre commands for music.
    public func activate(handlers: Handlers) {
        self.handlers = handlers
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlers.play() }
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlers.pause() }
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlers.togglePlayPause() }
            return .success
        }
        register(center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlers.nextTrack() }
            return .success
        }
        register(center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlers.previousTrack() }
            return .success
        }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = positionEvent.positionTime
            Task { @MainActor [weak self] in self?.handlers.seek(target) }
            return .success
        }
    }

    /// Releases media-key commands and clears the Now Playing card (e.g. when a film takes focus).
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        for (command, token) in tokens {
            command.removeTarget(token)
            command.isEnabled = false
        }
        tokens.removeAll()
        clear()
    }

    /// Updates which track-skipping buttons are enabled in Control Centre.
    public func setNavigationEnabled(next: Bool, previous: Bool) {
        guard isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = next
        center.previousTrackCommand.isEnabled = previous
    }

    /// Publishes the current track, queue index/count, position and artwork to `MPNowPlayingInfoCenter`.
    public func publish(
        track: QueuedTrack,
        position: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        queueIndex: Int,
        queueCount: Int,
        artwork: NSImage?
    ) {
        let safeDuration = max(0, duration)
        let safePosition = min(max(0, position), safeDuration > 0 ? safeDuration : max(0, position))

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: safeDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safePosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, queueIndex),
            MPNowPlayingInfoPropertyPlaybackQueueCount: max(1, queueCount),
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(artwork)
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Clears the Now Playing card without unregistering commands.
    public func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let token = command.addTarget(handler: handler)
        tokens.append((command, token))
    }

    /// MediaPlayer calls the artwork handler on its own queue. Built outside the main actor,
    /// the closure carries no actor isolation (a main-actor closure traps there).
    nonisolated private static func nowPlayingArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
