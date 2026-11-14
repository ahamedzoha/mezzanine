import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// The player in the "Bare Picture" layout (owner's pick): nothing but the
/// film until the pointer moves; then the title's clear logo top-left (the
/// owner asked for it, as in Jellyfin's TV apps), a close button, a hairline
/// scrub along the bottom edge and one ⋯ button. Skip Intro is the only full
/// button. Up Next takes over at the credits: the picture shrinks into the
/// corner and the next episode counts down beside it.
///
/// Keys (also in the Playback menu): Space/K play-pause, ←/→ J/L 10 s,
/// ↑/↓ volume to 400 %, S or Return skip, N next episode, D dialogue boost,
/// ⌥N night mode, F full screen, Esc closes panels then the player.
struct PlayerStage: View {
    let item: PlexMetadata
    let origin: CGRect?
    let window: CGSize

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(SoundSettings.self) private var sound
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    @State private var chromeVisible = true
    @State private var hideChrome: Task<Void, Never>?
    @State private var optionsOpen = false
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var upNext: UpNextState = .hidden
    @State private var autoSkipped = Set<String>()
    @State private var upNextTrigger: TimeInterval?
    @State private var pendingToggle: Task<Void, Never>?
    @FocusState private var focused: Bool

    enum UpNextState: Equatable { case hidden, counting(Int), dismissed, stillWatching }

    private var player: MezzaninePlayer { playback.player }
    private var upNextShown: Bool {
        switch upNext { case .counting, .stillWatching: return true; default: return false }
    }

    var body: some View {
        let frame = opened || origin == nil || reduceMotion ? CGRect(origin: .zero, size: window) : origin!
        ZStack {
            Color.black
            picture
            if upNextShown {
                GlassIconButton(symbol: "xmark", label: "Close Player", help: "Close (Esc)") { _ = perform(.close) }
                    .padding(.top, Theme.Space.xl).padding(.trailing, Theme.Space.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if chromeVisible || optionsOpen || player.status == .paused {
                chrome.transition(.opacity)
            }
            if !upNextShown { skipButton }
            if optionsOpen {
                PlayerOptions(item: item, close: { withAnimation(Theme.Motion.quick) { optionsOpen = false } })
                    .padding(.trailing, Theme.Space.gutter)
                    .padding(.bottom, 112)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
            if let flash { FlashGlyph(symbol: flash).transition(.opacity) }
            if let message = failure {
                PlaybackFailure(message: message,
                                retry: { Task { await playback.retry() } },
                                close: { playback.clearError(); _ = perform(.close) })
            }
            if let toast { SoundToast(text: toast, volume: sound.current.volumePercent).transition(.opacity) }
            upNextLayer
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: opened ? 0 : Theme.Radius.still, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
        .onAppear {
            focused = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 1)) { opened = true }
            scheduleHide()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PlayerOptionsOpen") { optionsOpen = true }
            #endif
        }
        .onDisappear { NSCursor.unhide() }
        .onContinuousHover { _ in showChrome() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            if optionsOpen { withAnimation(Theme.Motion.quick) { optionsOpen = false }; return .handled }
            if upNextShown { dismissUpNext(); return .handled }
            // In full screen, Esc leaves full screen first (macOS convention); the next Esc closes.
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return .handled }
            return perform(.close)
        }
        .onKeyPress(.space) { perform(.togglePlay) }
        .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in perform(.togglePlay) }
        .onKeyPress(.leftArrow) { perform(.back) }
        .onKeyPress(.rightArrow) { perform(.forward) }
        .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in perform(.back) }
        .onKeyPress(characters: CharacterSet(charactersIn: "lL")) { _ in perform(.forward) }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { _ in perform(.skipMarker) }
        .onKeyPress(characters: CharacterSet(charactersIn: "nN")) { press in
            guard !press.modifiers.contains(.option), playback.nextEpisode != nil else { return .ignored }
            Task { await playback.playNext(autoplayed: false) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onKeyPress(.return) {
            if case .counting = upNext { Task { await playback.playNext(autoplayed: false) }; return .handled }
            _ = perform(.skipMarker)
            return .handled
        }
        .onChange(of: commands.playerRequests.count) { _, _ in _ = perform(commands.playerRequests.action) }
        .onChange(of: activeMarker != nil, initial: true) { _, v in commands.hasActiveMarker = v }
        .onChange(of: playback.nextEpisode?.ratingKey, initial: true) { _, k in commands.hasNextEpisode = k != nil }
        .onChange(of: player.canPictureInPicture, initial: true) { _, v in commands.canPictureInPicture = v }
        .onChange(of: player.rate, initial: true) { _, r in commands.playbackRate = r }
        .onChange(of: upNext) { _, state in
            switch state {
            case .counting(let s) where s == playback.binge.upNextCountdown:
                if let next = playback.nextEpisode {
                    AccessibilityNotification.Announcement("Up next, \(next.title), plays in \(s) seconds. Return plays now, Escape hides.").post()
                }
            case .stillWatching:
                AccessibilityNotification.Announcement("Still watching? Playback paused.").post()
            default: break
            }
        }
        .onChange(of: player.status) { _, status in
            playback.reporter?.statusChanged()
            if status == .ended { handleEnded() }
        }
        .onChange(of: player.currentTime) { _, t in tick(t) }
        .onChange(of: item.ratingKey) { _, _ in resetForNewItem() }
        .onChange(of: sound.current) { old, new in
            if old.volumePercent != new.volumePercent { showToast("Volume \(Int(new.volumePercent)) %") }
            else if old.profile.dialogueGainDB != new.profile.dialogueGainDB { showToast(new.profile.dialogueGainDB > 0 ? "Dialogue boost on" : "Dialogue boost off") }
            else if old.profile.nightMode != new.profile.nightMode { showToast(new.profile.nightMode ? "Night mode on" : "Night mode off") }
            else if old.kind != new.kind { showToast(new.kind.label) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Picture

    /// The film; during Up Next it shrinks to its own shape beside the card.
    private var picture: some View {
        GeometryReader { geo in
            let rect = upNextShown ? UpNextLayout(size: geo.size, aspect: videoAspect).picture : CGRect(origin: .zero, size: geo.size)
            ZStack {
                PlayerSurface(player: player)
                SubtitleOverlay(player: player)
                // The video is an AppKit layer, so its rounding is painted in the stage's black
                // rather than left to SwiftUI clipping of a hosted view.
                PictureCorners(radius: upNextShown ? Theme.Radius.panel : 0)
                    .fill(Color.black, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            }
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: upNextShown ? Theme.Radius.panel : 0, style: .continuous))
            .shadow(color: .black.opacity(upNextShown ? 0.6 : 0), radius: 30, y: 14)
            .position(x: rect.midX, y: rect.midY)
            .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 1), value: upNextShown)
        }
        .contentShape(Rectangle())
        // Click toggles play; a double click (two toggles) leaves play as it was and goes full screen.
        .simultaneousGesture(TapGesture().onEnded {
            if optionsOpen { withAnimation(Theme.Motion.quick) { optionsOpen = false }; return }
            // Wait out the double-click interval so a double click doesn't pause and resume.
            pendingToggle?.cancel()
            pendingToggle = Task {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled else { return }
                _ = perform(.togglePlay)
            }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            pendingToggle?.cancel()
            NSApp.keyWindow?.toggleFullScreen(nil)
        })
    }

    // MARK: Chrome

    private var chrome: some View {
        ZStack {
            // A soft vignette top and bottom so the logo and type read over any frame.
            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 180)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 160)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    titleMark
                    Spacer()
                    GlassIconButton(symbol: "xmark", label: "Close Player", help: "Close (Esc)") { _ = perform(.close) }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.xl)
                Spacer()
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    Spacer()
                    if player.avPlayer != nil {
                        AirPlayButton(player: player)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
                            .help("AirPlay")
                            .accessibilityLabel("AirPlay")
                    }
                    if player.canPictureInPicture {
                        GlassIconButton(symbol: player.isPictureInPicture ? "pip.exit" : "pip.enter",
                                        label: "Picture in Picture", help: "Picture in Picture (⌥P)") { _ = perform(.pictureInPicture) }
                    }
                    GlassIconButton(symbol: "ellipsis", label: "Audio, subtitles, sound and speed", help: "Audio, subtitles, sound, speed") {
                        withAnimation(Theme.Motion.quick) { optionsOpen.toggle() }
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.m)
                HStack(spacing: Theme.Space.s) {
                    if player.status == .paused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(Theme.Typeface.cardMeta.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(clock(player.currentTime))
                    Spacer()
                    Text("−" + clock(max(0, player.duration - player.currentTime)))
                }
                .font(Theme.Typeface.cardMeta)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, -4)
                HairlineScrub(current: player.currentTime, duration: player.duration, markers: item.markers) { t in
                    Task { await player.seek(to: t) }
                }
            }
        }
    }

    /// Top-left: the title's clear logo (the text-logo art, not the poster), with the
    /// episode line under it; plain text when the title has no logo.
    private var titleMark: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            LogoImage(url: session.logoURL(item.clearLogoPath), pixelWidth: 640) {
                Text(Format.displayTitle(item)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: 300, maxHeight: 84, alignment: .topLeading)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            if item.kind == .episode {
                Text([Format.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typeface.caption).foregroundStyle(Theme.ink.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([Format.displayTitle(item), item.kind == .episode ? item.title : nil].compactMap { $0 }.joined(separator: ", "))
    }

    /// Width of the bottom-right icon row (AirPlay, PiP, options), so Skip sits beside it, never on it.
    private var iconRowWidth: CGFloat {
        let count = 1 + (player.avPlayer != nil ? 1 : 0) + (player.canPictureInPicture ? 1 : 0)
        return CGFloat(count) * 40 + CGFloat(count - 1) * Theme.Space.s
    }

    /// Skip Intro / Skip Credits: the only full button. Its fill drains as the marker plays.
    @ViewBuilder private var skipButton: some View {
        if let marker = activeMarker {
            let remaining = max(0, min(1, (marker.end - player.currentTime) / max(1, marker.end - marker.start)))
            Button { skip() } label: {
                HStack(spacing: 6) {
                    Text(marker.kind == .intro ? "Skip Intro" : (playback.nextEpisode != nil ? "Next Episode" : "Skip Credits"))
                    Image(systemName: "forward.fill").font(.system(size: 11, weight: .bold))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(Theme.onLilac.opacity(0.35)).frame(width: geo.size.width * remaining, height: 3)
                }
                .frame(height: 3).padding(.horizontal, 14).allowsHitTesting(false)
            }
            .focusEffectDisabled(false)
            .help("Skip (S or Return)")
            .padding(.trailing, Theme.Space.gutter + iconRowWidth + Theme.Space.m)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            .animation(Theme.Motion.object(reduceMotion), value: marker.kind)
        }
    }

    @ViewBuilder private var upNextLayer: some View {
        switch upNext {
        case .counting(let seconds):
            if let next = playback.nextEpisode {
                GeometryReader { geo in
                    let layout = UpNextLayout(size: geo.size, aspect: videoAspect)
                    UpNextCard(next: next, seconds: seconds, total: playback.binge.upNextCountdown,
                               playNow: { Task { await playback.playNext(autoplayed: false) } },
                               hide: { dismissUpNext() })
                        .frame(width: UpNextLayout.cardWidth, alignment: .topLeading)
                        .offset(x: layout.cardOrigin.x, y: layout.cardOrigin.y)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        case .stillWatching:
            StillWatchingCard(resume: { Task { await playback.playNext(autoplayed: false) } },
                              stop: { _ = perform(.close) })
                .transition(.opacity)
        default:
            EmptyView()
        }
    }

    // MARK: Behaviour

    /// The video's shape, from Plex's media facts (16:9 when unknown).
    private var videoAspect: CGFloat {
        if let media = item.media.first {
            // Exact pixels first; Plex rounds `aspectRatio` to the nearest standard ratio.
            if let w = media.width, let h = media.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
            if let a = media.aspectRatio, a > 0.5 { return CGFloat(a) }
        }
        return 16 / 9
    }

    /// A playback failure to show over the stage.
    private var failure: String? {
        if let error = playback.error { return error }
        if case .failed = player.status { return "This file couldn’t be played." }
        return nil
    }

    private var activeMarker: PlexMarker? {
        let t = player.currentTime
        return item.markers.first { ($0.kind == .intro || $0.kind == .credits) && t >= $0.start && t < $0.end - 1 }
    }

    /// Runs on every clock tick: automatic skips and the Up Next trigger.
    private func tick(_ t: TimeInterval) {
        if let marker = activeMarker {
            let key = "\(marker.kind)-\(marker.startTimeOffset)"
            if marker.kind == .intro, playback.autoSkipsIntro, !autoSkipped.contains(key) {
                autoSkipped.insert(key)
                Task { await player.seek(to: marker.end, exact: true) }
                showToast("Skipped intro")
            } else if marker.kind == .credits, playback.binge.autoSkipCredits, playback.nextEpisode != nil, !autoSkipped.contains(key) {
                autoSkipped.insert(key)
                Task { await playback.playNext(autoplayed: true) }
            }
        }
        if upNextTrigger == nil, player.duration > 0 {
            upNextTrigger = BingePlanner.upNextTrigger(duration: player.duration, markers: item.markers) ?? .infinity
        }
        guard upNext == .hidden, let trigger = upNextTrigger, t >= trigger,
              playback.nextEpisode != nil, playback.binge.upNextCountdown > 0, player.status == .playing else { return }
        playback.prewarmNext()
        startCountdown()
    }

    private func startCountdown() {
        withAnimation(Theme.Motion.object(reduceMotion)) { upNext = .counting(playback.binge.upNextCountdown) }
        Task {
            while case .counting(let s) = upNext {
                try? await Task.sleep(for: .seconds(1))
                guard case .counting(let current) = upNext, current == s else { return }
                if s <= 1 {
                    if playback.shouldAskStillWatching {
                        player.pause()
                        withAnimation(Theme.Motion.quick) { upNext = .stillWatching }
                    } else {
                        await playback.playNext(autoplayed: true)
                    }
                    return
                }
                upNext = .counting(s - 1)
            }
        }
    }

    private func dismissUpNext() {
        withAnimation(Theme.Motion.object(reduceMotion)) { upNext = .dismissed }
    }

    private func handleEnded() {
        if playback.nextEpisode != nil, upNext != .dismissed, playback.binge.upNextCountdown > 0 {
            if playback.shouldAskStillWatching { withAnimation { upNext = .stillWatching } }
            else { Task { await playback.playNext(autoplayed: true) } }
        } else {
            _ = perform(.close)
        }
    }

    private func resetForNewItem() {
        upNext = .hidden
        upNextTrigger = nil
        autoSkipped = []
        optionsOpen = false
        showChrome()
    }

    /// Every player key and Playback menu item lands here.
    @discardableResult
    private func perform(_ action: AppCommandCenter.PlayerAction) -> KeyPress.Result {
        showChrome()
        switch action {
        case .togglePlay:
            let willPlay = player.status != .playing
            player.togglePlayPause()
            flashGlyph(willPlay ? "play.fill" : "pause.fill")
        case .back: Task { await player.seek(by: -10) }; flashGlyph("gobackward.10")
        case .forward: Task { await player.seek(by: 10) }; flashGlyph("goforward.10")
        case .skipMarker: return skip() ? .handled : .ignored
        case .close: close()
        case .nextEpisode:
            guard playback.nextEpisode != nil else { return .ignored }
            Task { await playback.playNext(autoplayed: false) }
        case .pictureInPicture: player.togglePictureInPicture()
        case .speed(let rate): player.setRate(rate); showToast(rate == 1 ? "Normal speed" : String(format: "%g× speed", rate))
        }
        return .handled
    }

    @discardableResult
    private func skip() -> Bool {
        guard let marker = activeMarker else { return false }
        if marker.kind == .credits, playback.nextEpisode != nil {
            Task { await playback.playNext(autoplayed: false) }
        } else {
            Task { await player.seek(to: marker.end, exact: true) }
        }
        return true
    }

    private func close() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1)) { opened = false }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 280))
            playback.close()
        }
    }

    private func showChrome() {
        NSCursor.unhide()
        if !chromeVisible { withAnimation(Theme.Motion.quick) { chromeVisible = true } }
        scheduleHide()
    }

    private func scheduleHide() {
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.status == .playing, !optionsOpen, !NSWorkspace.shared.isVoiceOverEnabled,
                  !NSApp.isFullKeyboardAccessEnabled else { return }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PlayerChromePinned") { return }
            #endif
            withAnimation(.easeOut(duration: 0.4)) { chromeVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func flashGlyph(_ symbol: String) {
        withAnimation(Theme.Motion.quick) { flash = symbol }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { flash = nil }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(Theme.Motion.quick) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
        AccessibilityNotification.Announcement(text).post()
    }

    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Parts

/// A round dark-glass button (close, ⋯). Whole circle is the target.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.55)).interactive(), in: Circle())
        .focusEffectDisabled(false)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The transient play/pause/seek glyph in the middle of the picture.
private struct FlashGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 70, height: 70)
            .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A 2 pt line along the bottom edge; it thickens under the pointer and shows
/// the time there. Intro and credits read as slightly brighter segments.
struct HairlineScrub: View {
    let current: Double
    let duration: Double
    let markers: [PlexMarker]
    let seek: (Double) -> Void
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = duration > 0 ? min(1, current / duration) : 0
            let thick: CGFloat = hoverX == nil ? 2 : 6
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Theme.ink.opacity(0.3)).frame(height: thick)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    if duration > 0, m.kind == .intro || m.kind == .credits {
                        Rectangle().fill(Theme.ink.opacity(0.5))
                            .frame(width: max(2, w * (m.end - m.start) / duration), height: thick)
                            .offset(x: w * m.start / duration)
                    }
                }
                Rectangle().fill(Theme.ink).frame(width: max(2, w * p), height: thick)
                if let x = hoverX, duration > 0 {
                    Text(clock(Double(x / w) * duration))
                        .font(Theme.Typeface.cardMeta)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular.tint(.black.opacity(0.55)), in: Capsule())
                        .offset(x: min(max(0, x - 28), w - 64), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                withAnimation(Theme.Motion.quick) {
                    if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard duration > 0 else { return }
                seek(max(0, min(duration, Double(v.location.x / w) * duration)))
            })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(spoken(current)) of \(spoken(duration))")
        .accessibilityAddTraits(.updatesFrequently)
        .focusable()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, current + 10))
            case .decrement: seek(max(0, current - 10))
            @unknown default: break
            }
        }
    }

    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "1 hour 12 minutes 4 seconds", for VoiceOver.
    private func spoken(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0 seconds" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        return f.string(from: s) ?? ""
    }
}

/// Text and bitmap subtitles over the picture, styled from the ⋯ panel.
struct SubtitleOverlay: View {
    let player: MezzaninePlayer
    @AppStorage("subtitleScale") private var scale: Double = 1
    @AppStorage("subtitleBackground") private var background = false
    @AppStorage("subtitleOffset") private var offset: Double = 0

    var body: some View {
        let now = player.currentTime - offset
        let active = player.cues.filter { $0.start <= now && now < $0.end }
        GeometryReader { geo in
            // Size follows the picture so subtitles read the same in a window and full screen.
            let size = max(16, geo.size.height * 0.042) * scale
            VStack(spacing: 6) {
                ForEach(active) { cue in
                    switch cue.content {
                    case .text(let text):
                        Text(text)
                            .font(.system(size: size, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(background ? 0 : 0.9), radius: 2, y: 1)
                            .shadow(color: .black.opacity(background ? 0 : 0.6), radius: 6)
                            .padding(.horizontal, background ? 10 : 0)
                            .padding(.vertical, background ? 4 : 0)
                            .background(background ? RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.72)) : nil)
                            .padding(.horizontal, 24)
                    case .image(let image, _):
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxHeight: geo.size.height * 0.2 * scale)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, geo.size.height * 0.07)
        }
        .allowsHitTesting(false)
    }
}

/// A brief readout when volume or sound settings change.
private struct SoundToast: View {
    let text: String
    let volume: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(text).font(Theme.Typeface.button).foregroundStyle(Theme.ink)
            if text.hasPrefix("Volume") {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ink.opacity(0.2))
                        Capsule().fill(volume > 100 ? Theme.lilac : Theme.ink)
                            .frame(width: max(4, geo.size.width * volume / VolumeLevel.maximumPercent))
                        Rectangle().fill(Theme.ink.opacity(0.6)).frame(width: 1, height: 10)
                            .offset(x: geo.size.width * 100 / VolumeLevel.maximumPercent)
                    }
                }
                .frame(width: 180, height: 6)
                if volume > 100 {
                    Text("Boosted · the limiter keeps peaks clean").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(Theme.Space.m)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .padding(.top, 84)
        .padding(.trailing, Theme.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A playback failure over the stage, with Retry and Close.
private struct PlaybackFailure: View {
    let message: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Playback stopped", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: Theme.Space.m) {
                Button("Try Again", action: retry).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).focusEffectDisabled(false)
                Button("Close", action: close).buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
            }
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .onAppear { AccessibilityNotification.Announcement("Playback stopped. \(message)").post() }
    }
}

/// Where the shrunk picture and the Up Next card sit: side by side on the
/// 48 pt gutter, tops aligned, the pair centred vertically, the picture in its
/// own aspect ratio and never overlapping the card.
struct UpNextLayout {
    static let cardWidth: CGFloat = 380
    static let cardHeight: CGFloat = 440
    let size: CGSize
    let aspect: CGFloat

    private var gutter: CGFloat { Theme.Space.xxl }

    var picture: CGRect {
        let maxW = max(200, size.width - Self.cardWidth - gutter * 3)
        var w = min(maxW, size.width * 0.58)
        var h = w / aspect
        let maxH = size.height - gutter * 2
        if h > maxH { h = maxH; w = h * aspect }
        return CGRect(x: gutter, y: top(for: h), width: w, height: h)
    }

    var cardOrigin: CGPoint {
        let p = picture
        return CGPoint(x: p.maxX + gutter, y: p.minY)
    }

    private func top(for pictureHeight: CGFloat) -> CGFloat {
        max(gutter, (size.height - max(pictureHeight, Self.cardHeight)) / 2)
    }
}
