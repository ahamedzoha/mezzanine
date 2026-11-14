import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// The player, grown out of the frame it was opened from.
///
/// M0/D scope: picture, subtitles, a quiet HUD, skip intro/credits and the
/// core keys. The full HUD (track menus, volume to 400 %, Up Next) is its
/// own surface round in M3/M6.
struct PlayerStage: View {
    let item: PlexMetadata
    let origin: CGRect?
    let window: CGSize

    @Environment(PlaybackCoordinator.self) private var playback
    @State private var opened = false
    @State private var hudVisible = true
    @State private var hideHUD: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var player: MezzaninePlayer { playback.player }

    var body: some View {
        let frame = opened || origin == nil ? CGRect(origin: .zero, size: window) : origin!
        ZStack {
            Color.black
            PlayerSurface(player: player)
            SubtitleOverlay(player: player)
            if hudVisible { hud.transition(.opacity) }
            skipButton
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: opened ? 0 : Theme.Radius.still, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
        .onAppear {
            focused = true
            withAnimation(.spring(response: 0.5, dampingFraction: 1)) { opened = true }
            scheduleHUDHide()
        }
        .onContinuousHover { _ in
            withAnimation(Theme.Motion.quick) { hudVisible = true }
            scheduleHUDHide()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { player.togglePlayPause(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in player.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { Task { await player.seek(by: -10) }; return .handled }
        .onKeyPress(.rightArrow) { Task { await player.seek(by: 10) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in Task { await player.seek(by: -10) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "lL")) { _ in Task { await player.seek(by: 10) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { _ in skip() ? .handled : .ignored }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onKeyPress(.return) { skip() ? .handled : .ignored }
        .accessibilityLabel("Player")
    }

    // MARK: HUD

    private var hud: some View {
        VStack(spacing: 0) {
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.black.opacity(0.4)), in: Circle())
                .help("Close (Esc)")
                Spacer()
            }
            .padding(Theme.Space.l)
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(Format.displayTitle(item)).font(.system(size: 17, weight: .semibold))
                if item.kind == .episode {
                    Text([Format.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary)
                }
                ScrubBar(current: player.currentTime, duration: player.duration, markers: item.markers) { t in
                    Task { await player.seek(to: t) }
                }
                HStack {
                    Text(clock(player.currentTime))
                    Spacer()
                    Text("−" + clock(max(0, player.duration - player.currentTime)))
                }
                .font(Theme.Typeface.cardMeta)
                .foregroundStyle(Theme.inkSecondary)
            }
            .foregroundStyle(Theme.ink)
            .padding(Theme.Space.l)
            .glassEffect(.regular.tint(.black.opacity(0.4)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(Theme.Space.l)
        }
    }

    /// Skip Intro / Skip Credits: slides in while a marker plays.
    @ViewBuilder private var skipButton: some View {
        if let marker = activeMarker {
            Button { skip() } label: {
                Text(marker.kind == .intro ? "Skip Intro" : "Skip Credits")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Skip (S or Return)")
            .padding(.trailing, Theme.Space.xl)
            .padding(.bottom, 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(Theme.Motion.object, value: marker.kind)
        }
    }

    private var activeMarker: PlexMarker? {
        let t = player.currentTime
        return item.markers.first { ($0.kind == .intro || $0.kind == .credits) && t >= $0.start && t < $0.end - 1 }
    }

    @discardableResult
    private func skip() -> Bool {
        guard let marker = activeMarker else { return false }
        Task { await player.seek(to: marker.end, exact: true) }
        return true
    }

    private func close() {
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { opened = false }
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            playback.close()
        }
    }

    private func scheduleHUDHide() {
        hideHUD?.cancel()
        hideHUD = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.status == .playing else { return }
            withAnimation(.easeOut(duration: 0.4)) { hudVisible = false }
        }
    }

    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Progress with intro and credits marked on the track.
struct ScrubBar: View {
    let current: Double
    let duration: Double
    let markers: [PlexMarker]
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = duration > 0 ? min(1, current / duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.18))
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    if duration > 0, m.kind == .intro || m.kind == .credits {
                        Capsule().fill(Theme.ink.opacity(0.32))
                            .frame(width: max(2, w * (m.end - m.start) / duration))
                            .offset(x: w * m.start / duration)
                    }
                }
                Capsule().fill(Theme.ink).frame(width: max(4, w * p))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard duration > 0 else { return }
                seek(max(0, min(duration, Double(v.location.x / w) * duration)))
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(current / 60)) of \(Int(duration / 60)) minutes")
    }
}

/// Text and bitmap subtitles over the picture.
struct SubtitleOverlay: View {
    let player: MezzaninePlayer

    var body: some View {
        let now = player.currentTime
        let active = player.cues.filter { $0.start <= now && now < $0.end }
        VStack(spacing: 6) {
            ForEach(active) { cue in
                switch cue.content {
                case .text(let text):
                    Text(text)
                        .font(.system(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        .padding(.horizontal, 24)
                case .image(let image, _):
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 160)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 56)
        .allowsHitTesting(false)
    }
}
