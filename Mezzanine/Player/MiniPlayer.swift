import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// The film in a corner tile while the window goes back to browsing (the owner's pick: the
/// corner of the window, not a separate window; Picture in Picture already floats over other
/// apps). Bottom-right on the 24 pt inset, 340 pt wide at the film's shape. Hover shows the
/// title, play/pause, expand and close on dark glass; a click grows it back into the player.
/// Keys: ⌥M (Playback ▸ Mini Player) expands; the Playback menu's play, skip, volume and
/// next-episode items act on the tile. At the end of an episode the next one plays when Up
/// Next autoplay is on; otherwise the tile closes.
struct MiniPlayerTile: View {
    let item: PlexMetadata

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    static let width: CGFloat = 340

    private var player: MezzaninePlayer { playback.player }

    private var aspect: CGFloat {
        if let media = item.media.first, let w = media.width, let h = media.height, w > 0, h > 0 {
            return max(1.2, min(2.4, CGFloat(w) / CGFloat(h)))
        }
        return 16 / 9
    }

    var body: some View {
        tile
            .padding(.trailing, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            .onChange(of: commands.playerRequests.count) { _, _ in handle(commands.playerRequests.action) }
            .onChange(of: player.status) { _, status in if status == .ended { finished() } }
            #if DEBUG
            // -MiniExpandAfter 4: grows back after that many seconds (walkthrough captures).
            .task {
                let after = UserDefaults.standard.integer(forKey: "MiniExpandAfter")
                guard after > 0 else { return }
                try? await Task.sleep(for: .seconds(after))
                print("MINI expand")
                expand()
            }
            #endif
    }

    private var tile: some View {
        let size = CGSize(width: Self.width, height: Self.width / aspect)
        return ZStack {
            Color.black
            PlayerSurface(player: player)
            SubtitleOverlay(player: player, onDevice: playback.onDevice, compact: true)
            if player.isBuffering || player.status == .loading { ProgressView().controlSize(.small).tint(Theme.ink) }
            // Always in the tree (Full Keyboard Access and VoiceOver reach them); shown on hover.
            controls.opacity(hovering || player.status == .paused ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) { progress }
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.quick) { hovering = inside } }
        .onTapGesture { expand() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .modifier(TileAccessibility(title: Format.displayTitle(item), value: accessibilityValue,
                                    playing: player.status == .playing,
                                    expand: expand, toggle: { player.togglePlayPause() }, close: { playback.close() }))
    }

    private var accessibilityValue: String {
        "\(player.status == .playing ? "Playing" : "Paused"), \(Format.clock(player.currentTime)) of \(Format.clock(player.duration))"
    }

    // MARK: Parts

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(Theme.Typeface.cardMeta.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.top, 8)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    button(player.status == .playing ? "pause.fill" : "play.fill",
                           label: player.status == .playing ? "Pause" : "Play") { player.togglePlayPause() }
                    Spacer(minLength: 0)
                    button("arrow.up.left.and.arrow.down.right", label: "Expand Player", help: "Expand Player (\(PlayerShortcuts.shared.display(.miniPlayer)))") { expand() }
                    button("xmark", label: "Close Player") { playback.close() }
                }
                .padding(8)
            }
        }
    }

    private func button(_ symbol: String, label: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    private var progress: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
            Rectangle().fill(Theme.ink).frame(width: geo.size.width * fraction, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var caption: String {
        [Format.displayTitle(item), item.kind == .episode ? Format.episodeCode(item) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Actions

    private func expand() {
        playback.expand(from: frame)
    }

    /// The Playback menu while the tile plays: the everyday items act here; anything that
    /// needs the full player (tracks, panels, frames) grows it back first.
    private func handle(_ action: AppCommandCenter.PlayerAction) {
        switch action {
        case .close: playback.close()
        case .key(let key):
            switch key {
            case .playPause: player.togglePlayPause()
            case .back10: Task { await player.seek(by: -10) }
            case .forward10: Task { await player.seek(by: 10) }
            case .back60: Task { await player.seek(by: -60) }
            case .forward60: Task { await player.seek(by: 60) }
            case .mute: player.setMuted(!player.isMuted)
            case .volumeUp: player.volume = VolumeLevel(percent: min(VolumeLevel.maximumPercent, player.volume.percent + 10))
            case .volumeDown: player.volume = VolumeLevel(percent: max(0, player.volume.percent - 10))
            case .nextEpisode: Task { await playback.playNext(autoplayed: false) }
            case .previousEpisode: Task { await playback.playPrevious() }
            case .miniPlayer: expand()
            case .fullScreen: NSApp.keyWindow?.toggleFullScreen(nil)
            default: expand()
            }
        case .speed(let rate): player.setRate(rate)
        case .jump, .picture, .cast, .snapshot: expand()
        }
    }

    /// The episode ended in the corner: the next one follows if Up Next autoplay is on.
    private func finished() {
        if playback.nextEpisode != nil, playback.binge.upNextCountdown > 0 {
            Task { await playback.playNext(autoplayed: true) }
        } else {
            AccessibilityNotification.Announcement("Finished \(Format.displayTitle(item))").post()
            playback.close()
        }
    }
}

/// The tile as VoiceOver meets it: a button that expands, with play and close actions.
private struct TileAccessibility: ViewModifier {
    let title: String
    let value: String
    let playing: Bool
    let expand: () -> Void
    let toggle: () -> Void
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini player: \(title)")
            .accessibilityValue(value)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Expand Player") { expand() }
            .accessibilityAction(named: playing ? "Pause" : "Play") { toggle() }
            .accessibilityAction(named: "Close Player") { close() }
    }
}
