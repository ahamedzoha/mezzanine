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
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    @State private var hudVisible = true
    @State private var hideHUD: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var player: MezzaninePlayer { playback.player }

    var body: some View {
        let frame = opened || origin == nil || reduceMotion ? CGRect(origin: .zero, size: window) : origin!
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
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 1)) { opened = true }
            scheduleHUDHide()
        }
        .onDisappear { NSCursor.unhide() }
        .onContinuousHover { _ in showHUD() }
        // The player is the only thing on screen; its own controls keep their focus indication.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { perform(.close) }
        .onKeyPress(.space) { perform(.togglePlay) }
        .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in perform(.togglePlay) }
        .onKeyPress(.leftArrow) { perform(.back) }
        .onKeyPress(.rightArrow) { perform(.forward) }
        .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in perform(.back) }
        .onKeyPress(characters: CharacterSet(charactersIn: "lL")) { _ in perform(.forward) }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { _ in perform(.skipMarker) }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        // Return skips while a marker plays and is swallowed otherwise, so it never reaches anything behind the player.
        .onKeyPress(.return) { _ = perform(.skipMarker); return .handled }
        .onChange(of: commands.playerRequests.count) { _, _ in _ = perform(commands.playerRequests.action) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
        .accessibilityAddTraits(.isModal)
    }

    /// Every player key and Playback menu item lands here.
    @discardableResult
    private func perform(_ action: AppCommandCenter.PlayerAction) -> KeyPress.Result {
        showHUD()
        switch action {
        case .togglePlay: player.togglePlayPause()
        case .back: Task { await player.seek(by: -10) }
        case .forward: Task { await player.seek(by: 10) }
        case .skipMarker: return skip() ? .handled : .ignored
        case .close: close()
        }
        return .handled
    }

    private func showHUD() {
        NSCursor.unhide()
        withAnimation(Theme.Motion.quick) { hudVisible = true }
        scheduleHUDHide()
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
                .glassEffect(.regular.tint(.black.opacity(0.55)).interactive(), in: Circle())
                .focusEffectDisabled(false)
                .help("Close (Esc)")
                .accessibilityLabel("Close Player")
                Spacer()
            }
            .padding(Theme.Space.l)
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(Format.displayTitle(item)).font(Theme.Typeface.shelfTitle)
                if item.kind == .episode {
                    Text([Format.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary)
                }
                ScrubBar(current: player.currentTime, duration: player.duration, markers: item.markers) { t in
                    Task { await player.seek(to: t) }
                }
                .accessibilityValue("\(clock(player.currentTime)) of \(clock(player.duration))")
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
            .glassEffect(.regular.tint(.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
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
            .focusEffectDisabled(false)
            .help("Skip (S or Return)")
            .padding(.trailing, Theme.Space.xl)
            .padding(.bottom, 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            .animation(Theme.Motion.object(reduceMotion), value: marker.kind)
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1)) { opened = false }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 280))
            playback.close()
        }
    }

    private func scheduleHUDHide() {
        hideHUD?.cancel()
        hideHUD = Task {
            try? await Task.sleep(for: .seconds(2.5))
            // VoiceOver users keep the controls; they can't chase a disappearing HUD.
            guard !Task.isCancelled, player.status == .playing, !NSWorkspace.shared.isVoiceOverEnabled else { return }
            withAnimation(.easeOut(duration: 0.4)) { hudVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
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
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, current + 10))
            case .decrement: seek(max(0, current - 10))
            @unknown default: break
            }
        }
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
