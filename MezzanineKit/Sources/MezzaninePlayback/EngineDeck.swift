import Foundation
import Combine
import AetherEngine
import MezzanineKit

/// The music engine's second deck: an AetherEngine instance of its own (never
/// `MezzaninePlayer.shared`, which belongs to films) that streams a file from the server.
///
/// It plays what the native deck decodes badly or not at all: Vorbis (seeks 896 frames off on
/// `AVAudioFile`), WMA (will not open), E-AC-3 / 5.1, anything `AVAudioFile` refuses, and a
/// first track whose download is not ready in time. Joins to and from this deck are not
/// gapless (the engine loads one source at a time).
///
/// It never touches system Now Playing: `ownsAudioNowPlaying` stays false, so the engine plans
/// no publisher for audio and registers no remote commands; `NowPlayingPublisher` owns the card.
@MainActor
final class EngineDeck {
    private let engine: AetherEngine
    private var bag = Set<AnyCancellable>()
    private var loadGeneration = 0

    private(set) var status: MusicStatus = .idle
    private(set) var duration: TimeInterval = 0
    /// Called when the loaded source plays to its end, or fails; carries the load it belongs to.
    var onEnded: (@MainActor (_ failure: String?) -> Void)?

    init() throws {
        engine = try AetherEngine()
        engine.ownsAudioNowPlaying = false
        engine.ownsVideoNowPlayingSession = false
        engine.ownsVideoNowPlayingCommands = false
        engine.ownsSoftwareNowPlaying = false
        bind()
    }

    var position: TimeInterval { engine.clock.currentTime }

    /// Volume 0…1 (the engine's own volume, with leveling gain folded in and capped at 1).
    var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    func load(url: URL, headers: [String: String], startAt: TimeInterval, autoplay: Bool, volume: Float) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        status = .loading
        var options = LoadOptions(httpHeaders: headers)
        options.audioOnly = true
        options.autoplay = autoplay
        engine.volume = volume
        do {
            try await engine.load(url: url, startPosition: startAt > 0 ? startAt : nil, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == loadGeneration { status = .failed(String(describing: error)) }
            throw error
        }
        guard generation == loadGeneration else { throw CancellationError() }
        duration = engine.duration
    }

    func play() { engine.play() }
    func pause() { engine.pause() }

    func seek(to seconds: TimeInterval) async {
        await engine.seek(to: max(0, seconds), exact: true)
    }

    func stop() {
        loadGeneration += 1
        engine.stop()
        status = .idle
        duration = 0
    }

    private func bind() {
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            let generation = self.loadGeneration
            switch state {
            case .idle: self.status = .idle
            case .loading, .seeking: self.status = .loading
            case .playing: self.status = .playing
            case .paused: self.status = .paused
            case .ended:
                self.status = .ended
                if generation == self.loadGeneration { self.onEnded?(nil) }
            case .error(let message):
                self.status = .failed(message)
                if generation == self.loadGeneration { self.onEnded?(message) }
            }
        }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] in self?.duration = $0 }.store(in: &bag)
    }
}
