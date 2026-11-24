import SwiftUI
import Translation
import MezzanineKit
import MezzaninePlayback

/// The player in the "Bare Picture" layout (owner's pick): nothing but the
/// film until the pointer moves; then the title's clear logo top-left (the
/// owner asked for it, as in Jellyfin's TV apps), a close button, a hairline
/// scrub along the bottom edge and one ⋯ button. Skip Intro is the only full
/// button. Up Next takes over at the credits: the picture shrinks into the
/// corner and the next episode counts down beside it.
///
/// Keys: every player key is rebindable (`PlayerShortcuts`, Settings ▸ Shortcuts) and is
/// also a Playback menu item. `PlayerKeyRouter` delivers them here ahead of the menus.
/// Fixed: Return skips / plays Up Next now, Esc steps out (panel page, panel, Up Next,
/// full screen, player), 0–9 jump through the film, ⌘⇧S takes a snapshot.
struct PlayerStage: View {
    let item: PlexMetadata
    let origin: CGRect?
    let window: CGSize

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(SoundSettings.self) private var sound
    @Environment(SessionStore.self) private var session
    @Environment(DownloadStore.self) private var downloads
    @Environment(SubtitleSourceSettings.self) private var subtitleSources
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
    /// The highlighted suggestion in a film's post-play.
    @State private var postPlaySelection = 0
    @State private var pendingToggle: Task<Void, Never>?
    @State private var optionsPage: PlayerOptions.Page = .root
    @State private var goingToTime = false
    @AppStorage("playerStatsVisible") private var statsVisible = false
    @AppStorage("subtitleOffset") private var subtitleOffset: Double = 0
    @FocusState private var focused: Bool

    enum UpNextState: Equatable { case hidden, counting(Int), dismissed, stillWatching, postPlay }

    private var player: MezzaninePlayer { playback.player }
    private var upNextShown: Bool {
        switch upNext { case .counting, .stillWatching, .postPlay: return true; default: return false }
    }

    var body: some View {
        let frame = opened || origin == nil || reduceMotion ? CGRect(origin: .zero, size: window) : origin!
        ZStack {
            Color.black
            picture
            // Casting: the TV's panel sits over the picture and under the player's own controls.
            if playback.cast.isCasting || isCastFailure { CastingPanel(item: item).transition(.opacity) }
            if upNextShown {
                GlassIconButton(symbol: "xmark", label: "Close Player", help: "Close (Esc)") { _ = perform(.close) }
                    .padding(.top, Theme.Space.xl).padding(.trailing, Theme.Space.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if chromeVisible || optionsOpen || player.status == .paused {
                chrome.transition(.opacity)
            }
            if !upNextShown && !playback.cast.isCasting { skipButton }
            if statsVisible && !upNextShown { PlayerStats(item: item).transition(.opacity) }
            if optionsOpen {
                PlayerOptions(item: item, page: $optionsPage, close: { setOptions(open: false) })
                    .padding(.trailing, Theme.Space.gutter)
                    .padding(.bottom, 112)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
            if goingToTime {
                GoToTimeField(duration: player.duration, go: { t in
                    setGoToTime(false)
                    Task { await player.seek(to: t, exact: true) }
                    showToast(Format.clock(t))
                }, close: { setGoToTime(false) })
                    .padding(.bottom, 112)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
            if let seconds = playback.sleep.stopping, !upNextShown {
                StoppingSoonCard(seconds: seconds) { playback.sleep.keepWatching() }.transition(.opacity)
            }
            if let flash { FlashGlyph(symbol: flash).transition(.opacity) }
            if let message = failure {
                PlaybackFailure(message: message,
                                retry: { Task { await playback.retry() } },
                                convert: playback.mode == .direct ? { Task { await playback.setMode(.convert(nil)) } } : nil,
                                close: { playback.clearError(); _ = perform(.close) })
            }
            // A brief readout wins; otherwise a running on-device task (model download, timing
            // match) holds its own until it ends.
            if let text = toast ?? playback.onDevice.status {
                SoundToast(text: text, volume: sound.current.volumePercent).transition(.opacity)
            }
            upNextLayer
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: opened ? 0 : Theme.Radius.still, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
        .onAppear {
            focused = true
            playback.cast.startDiscovery()
            #if DEBUG
            // -CastTo "Family" -CastStopAfter 25: casts to that device once playback runs, then stops.
            if let name = UserDefaults.standard.string(forKey: "CastTo") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    print("CAST devices=\(playback.cast.devices.map(\.name))")
                    guard let device = playback.cast.devices.first(where: { $0.name.hasPrefix(name) }) else { return }
                    await playback.startCasting(to: device)
                    let stopAfter = UserDefaults.standard.integer(forKey: "CastStopAfter")
                    if stopAfter > 0 {
                        try? await Task.sleep(for: .seconds(stopAfter))
                        print("CAST stopping at \(playback.cast.position)")
                        await playback.stopCasting()
                        try? await Task.sleep(for: .seconds(2))
                        print("CAST local resumed at \(player.currentTime) status=\(player.status)")
                    }
                }
            }
            #endif
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 1)) { opened = true }
            scheduleHide()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PlayerOptionsOpen") { optionsOpen = true }
            // -PlayerOptionsPage search|subtitles|audio: open the ⋯ panel on that page.
            switch UserDefaults.standard.string(forKey: "PlayerOptionsPage") {
            case "search": optionsPage = .search; optionsOpen = true
            case "subtitles": optionsPage = .subtitles; optionsOpen = true
            case "audio": optionsPage = .audio; optionsOpen = true
            case "picture": optionsPage = .picture; optionsOpen = true
            case "sleep": optionsPage = .sleep; optionsOpen = true
            default: break
            }
            // -PlayerKeyScript "i,c,g,shift+c": posts real key events through the app's event
            // queue (router, menus) after 4 s, 0.6 s apart, for review captures.
            if let script = UserDefaults.standard.string(forKey: "PlayerKeyScript"), !DebugKeys.scriptRan {
                DebugKeys.scriptRan = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    for token in script.split(separator: ",") {
                        // "!snapshot": the menu action itself (menus ignore keys while the app is in the background).
                        // "~3": wait that many seconds (full-screen transitions take a moment).
                        if token.hasPrefix("~") { try? await Task.sleep(for: .seconds(Double(token.dropFirst()) ?? 1)); continue }
                        if token == "!fs" { NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.toggleFullScreen(nil); continue }
                        if token == "!snapshot" { _ = perform(.snapshot) } else { DebugKeys.post(String(token)) }
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                }
            }
            // -PlayerQuality remux|convert|8000: switch delivery after 3 s (fallback tests).
            if let q = UserDefaults.standard.string(forKey: "PlayerQuality") {
                let mode: PlaybackMode = q == "remux" ? .remux : (q == "convert" ? .convert(nil) : .convert(Int(q)))
                Task { try? await Task.sleep(for: .seconds(3)); await playback.setMode(mode) }
            }
            if UserDefaults.standard.bool(forKey: "PlayerFullScreen") {
                Task { try? await Task.sleep(for: .seconds(1)); NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.toggleFullScreen(nil) }
            }
            #endif
        }
        .onDisappear { NSCursor.unhide() }
        .onContinuousHover { _ in showChrome() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .background(WindowReader { window in
            PlayerKeyRouter.shared.attach(window: window) { event, key in handleKey(event, key) }
        })
        .onDisappear { PlayerKeyRouter.shared.detach() }
        .onChange(of: commands.playerRequests.count) { _, _ in _ = perform(commands.playerRequests.action) }
        .onChange(of: activeMarker != nil, initial: true) { _, v in commands.hasActiveMarker = v }
        .onChange(of: playback.nextEpisode?.ratingKey, initial: true) { _, k in commands.hasNextEpisode = k != nil }
        .onChange(of: playback.previousEpisode?.ratingKey, initial: true) { _, k in commands.hasPreviousEpisode = k != nil }
        .onChange(of: player.isMuted, initial: true) { _, v in commands.isMuted = v }
        .onChange(of: playback.fallbackNotice) { _, notice in if let notice { showToast(notice) } }
        .onChange(of: playback.mode) { old, new in
            if playback.fallbackNotice == nil, old != new { showToast("Quality: " + new.label) }
        }
        .onChange(of: statsVisible, initial: true) { _, v in commands.statsVisible = v }
        .onChange(of: player.canPictureInPicture, initial: true) { _, v in commands.canPictureInPicture = v }
        .onChange(of: player.rate, initial: true) { _, r in commands.playbackRate = r }
        .modifier(OnDeviceHost(onDevice: playback.onDevice, commands: commands, toast: { showToast($0, long: $1) }))
        .onChange(of: playback.pictureMode, initial: true) { _, m in commands.pictureMode = m.rawValue }
        .onChange(of: playback.cast.devices.map(\.id), initial: true) { _, _ in
            commands.castTargets = playback.cast.devices.map { ($0.id, $0.name) }
        }
        .onChange(of: playback.cast.isCasting, initial: true) { _, casting in
            commands.castingTo = casting ? playback.cast.device?.id : nil
        }
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
        // Stopped by the sleep timer: Up Next must not go on counting.
        .onChange(of: playback.sleep.stops) { _, _ in
            if case .counting = upNext { withAnimation(Theme.Motion.quick) { upNext = .stillWatching } }
            showToast("Sleep timer: paused")
        }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: playback.sleep.stopping != nil)
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
                // Zoom lays the picture out larger than the window (the window crops it); the
                // subtitles stay inside the window.
                let zoom = upNextShown ? 1 : playback.pictureMode.scale
                PlayerSurface(player: player)
                    .frame(width: rect.width * zoom, height: rect.height * zoom)
                    .frame(width: rect.width, height: rect.height)
                if !playback.cast.isCasting { SubtitleOverlay(player: player, onDevice: playback.onDevice) }
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
            if goingToTime { setGoToTime(false); return }
            // Wait out the double-click interval so a double click doesn't pause and resume.
            pendingToggle?.cancel()
            pendingToggle = Task {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled else { return }
                _ = perform(.key(.playPause))
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
                    CastButton()
                    if player.avPlayer != nil {
                        AirPlayButton(player: player)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
                            .help("AirPlay")
                            .accessibilityLabel("AirPlay")
                    }
                    if player.canPictureInPicture {
                        GlassIconButton(symbol: player.isPictureInPicture ? "pip.exit" : "pip.enter",
                                        label: "Picture in Picture", help: PlayerShortcuts.shared.help("Picture in Picture", .pictureInPicture)) { _ = perform(.key(.pictureInPicture)) }
                    }
                    if !playback.cast.isCasting {
                        GlassIconButton(symbol: "rectangle.inset.bottomright.filled", label: "Mini Player",
                                        help: PlayerShortcuts.shared.help("Mini player: keep browsing", .miniPlayer)) { _ = perform(.key(.miniPlayer)) }
                    }
                    GlassIconButton(symbol: "ellipsis", label: "Audio, subtitles, sound and speed",
                                    help: PlayerShortcuts.shared.help("Audio, subtitles, sound, speed", .options)) {
                        setOptions(open: !optionsOpen)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.m)
                // While casting, the TV's position is in the panel; the Mac's paused one would mislead.
                if !playback.cast.isCasting {
                HStack(spacing: Theme.Space.s) {
                    if player.status == .paused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(Theme.Typeface.cardMeta.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(clock(player.currentTime))
                    Spacer()
                    remainingLine
                }
                .font(Theme.Typeface.cardMeta)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, -4)
                HairlineScrub(current: player.currentTime, duration: player.duration, markers: item.markers,
                              chapters: chapterStarts,
                              preview: { [player] t in await player.previewFrame(at: t, maxWidth: 400) }) { t in
                    Task { await player.seek(to: t) }
                }
                // A new title gets a fresh bar: hover previews are cached per position.
                .id(item.ratingKey)
                }
            }
        }
    }

    /// "−44:02 · Ends 23:42", and the sleep timer while one is set.
    private var remainingLine: some View {
        // The clock moves on while the film is paused.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: Theme.Space.s) {
                if playback.sleep.isOn {
                    Label(playback.sleep.label(for: item), systemImage: "moon.zzz")
                        .help(PlayerShortcuts.shared.help("Sleep timer", .sleepTimer))
                        .accessibilityLabel("Sleep timer: \(playback.sleep.label(for: item))")
                    Text("·").accessibilityHidden(true)
                }
                Text("−" + clock(max(0, player.duration - player.currentTime)))
                if let end = TimeEntry.end(current: player.currentTime, duration: player.duration, rate: player.rate, now: context.date) {
                    Text("· Ends \(end.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
    }

    /// Top-left: the title's clear logo (the text-logo art, not the poster), with the
    /// episode line under it; plain text when the title has no logo.
    private var titleMark: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Offline, a download's saved logo stands in for the server's.
            LogoImage(url: session.logoURL(item.clearLogoPath)
                        ?? downloads.record(item.ratingKey).flatMap { downloads.url($0.logoFile) }, pixelWidth: 640) {
                Text(Format.displayTitle(item)).font(.system(.title, weight: .semibold)).foregroundStyle(Theme.ink)
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
        case .postPlay:
            GeometryReader { geo in
                let layout = UpNextLayout(size: geo.size, aspect: videoAspect)
                PostPlayCard(title: playback.suggestionsTitle, suggestions: playback.suggestions, selected: postPlaySelection,
                             select: { postPlaySelection = $0 },
                             play: { next in Task { await playback.playSuggestion(next) } },
                             replay: { replay() },
                             hide: { dismissUpNext() })
                    .frame(width: UpNextLayout.cardWidth, alignment: .topLeading)
                    .offset(x: layout.cardOrigin.x, y: layout.cardOrigin.y)
            }
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
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
        // Films: at the credits, suggestions instead of a countdown.
        if item.kind == .movie, upNext == .hidden, playback.showsPostPlay, let trigger = upNextTrigger, t >= trigger,
           player.status == .playing {
            showPostPlay()
            return
        }
        guard upNext == .hidden, let trigger = upNextTrigger, t >= trigger,
              playback.nextEpisode != nil, playback.binge.upNextCountdown > 0, player.status == .playing,
              !playback.sleep.timer.stopsAtEnd else { return }
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

    private func showPostPlay() {
        postPlaySelection = 0
        Task {
            await playback.loadSuggestions()
            if let first = playback.suggestions.first {
                AccessibilityNotification.Announcement("\(playback.suggestionsTitle). \(first.title) and \(playback.suggestions.count - 1) more. Return plays, Escape hides.").post()
            }
        }
        withAnimation(Theme.Motion.object(reduceMotion)) { upNext = .postPlay }
    }

    private func replay() {
        withAnimation(Theme.Motion.object(reduceMotion)) { upNext = .dismissed }
        upNextTrigger = nil
        Task {
            await player.seek(to: 0)
            player.play()
            // Shown again at this viewing's credits.
            upNext = .hidden
        }
    }

    private func dismissUpNext() {
        withAnimation(Theme.Motion.object(reduceMotion)) { upNext = .dismissed }
    }

    private func handleEnded() {
        // A film's suggestions stay up at the end until you choose (or close).
        if upNext == .postPlay { _ = playback.sleep.titleEnded(); return }
        // The sleep timer ends here: the next episode waits to be asked for.
        if playback.sleep.titleEnded() {
            if playback.nextEpisode != nil { withAnimation { upNext = .stillWatching } } else { _ = perform(.close) }
            return
        }
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
        goingToTime = false
        showChrome()
    }

    /// A key from `PlayerKeyRouter`: the fixed keys first, then the rebindable table.
    /// Returns false to hand the key to whatever has focus (a focused button's Space).
    private func handleKey(_ event: NSEvent, _ key: PlayerKey?) -> Bool {
        let navigation: Set<UInt16> = [KeyBinding.space, KeyBinding.left, KeyBinding.right, KeyBinding.up,
                                       KeyBinding.down, KeyBinding.returnKey, KeyBinding.enter]
        // Full Keyboard Access: with focus on a control, Space/Return/arrows drive the focus.
        if NSApp.isFullKeyboardAccessEnabled, !focused, navigation.contains(event.keyCode) { return false }
        switch event.keyCode {
        case KeyBinding.escape: escape(); return true
        case KeyBinding.returnKey, KeyBinding.enter: returnKey(); return true
        default: break
        }
        // Post-play: the arrows choose a suggestion (3 per row) instead of seeking.
        if upNext == .postPlay, !playback.suggestions.isEmpty, !event.modifierFlags.contains(.option) {
            let delta: Int? = switch event.keyCode {
            case KeyBinding.left: -1
            case KeyBinding.right: 1
            case KeyBinding.up: -3
            case KeyBinding.down: 3
            default: nil
            }
            if let delta {
                postPlaySelection = min(max(0, postPlaySelection + delta), playback.suggestions.count - 1)
                AccessibilityNotification.Announcement(playback.suggestions[postPlaySelection].title).post()
                return true
            }
        }
        if let key { return perform(.key(key)) == .handled }
        if !event.modifierFlags.contains(.option), let c = event.charactersIgnoringModifiers,
           c.count == 1, let digit = Int(c) {
            return perform(.jump(digit)) == .handled
        }
        return false
    }

    /// Esc steps out one layer at a time: panel page, panel, Up Next, full screen, player.
    private func escape() {
        if failure != nil { playback.clearError(); _ = perform(.close); return }
        if optionsOpen {
            if optionsPage != .root { optionsPage = optionsPage == .search ? .subtitles : .root } else { setOptions(open: false) }
            return
        }
        if goingToTime { setGoToTime(false); return }
        if playback.sleep.stopping != nil, !upNextShown { playback.sleep.keepWatching(); return }
        if upNextShown { dismissUpNext(); return }
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return }
        _ = perform(.close)
    }

    /// Return: Try Again on a failure, Up Next plays now, Still Watching resumes, else skip.
    private func returnKey() {
        if failure != nil { Task { await playback.retry() }; return }
        if playback.sleep.stopping != nil, !upNextShown { playback.sleep.keepWatching(); return }
        switch upNext {
        case .counting, .stillWatching: Task { await playback.playNext(autoplayed: false) }
        case .postPlay:
            let list = playback.suggestions
            if list.indices.contains(postPlaySelection) { Task { await playback.playSuggestion(list[postPlaySelection]) } }
        default: _ = perform(.key(.skipMarker))
        }
    }

    private func setGoToTime(_ open: Bool) {
        withAnimation(Theme.Motion.quick) {
            if open { optionsOpen = false }
            goingToTime = open
        }
        if !open { focused = true }
    }

    private func setOptions(open: Bool, page: PlayerOptions.Page = .root) {
        withAnimation(Theme.Motion.quick) {
            optionsPage = page
            optionsOpen = open
        }
    }

    /// Every player key and Playback menu item lands here.
    @discardableResult
    private func perform(_ action: AppCommandCenter.PlayerAction) -> KeyPress.Result {
        showChrome()
        switch action {
        case .key(let key): return perform(key)
        case .speed(let rate): setRate(rate)
        case .cast(let id):
            if let id, let device = playback.cast.devices.first(where: { $0.id == id }) {
                Task { await playback.startCasting(to: device) }
            } else {
                Task { await playback.stopCasting() }
            }
        case .picture(let raw):
            guard let mode = PictureMode(rawValue: raw) else { return .ignored }
            withAnimation(Theme.Motion.object(reduceMotion)) { playback.pictureMode = mode }
            showToast("Picture: " + mode.label)
        case .jump(let digit):
            guard player.duration > 0 else { return .ignored }
            Task { await player.seek(to: player.duration * Double(digit) / 10) }
            showToast(digit == 0 ? "Start" : "\(digit * 10) %")
        case .sleep(let choice):
            playback.sleep.set(choice)
            showToast(choice == .off ? "Sleep timer off" : "Sleep timer: \(playback.sleep.label(for: item))")
        case .snapshot: takeSnapshot()
        case .close: close()
        }
        return .handled
    }

    private var isCastFailure: Bool {
        if case .failed = playback.cast.state { return true }
        return false
    }

    /// While casting, the transport keys drive the TV; after a failed cast, Space resumes here.
    private func performOnTV(_ key: PlayerKey) -> KeyPress.Result? {
        let cast = playback.cast
        if isCastFailure {
            if key == .playPause { cast.clearFailure(); return .handled }
            return key == .options || key == .fullScreen ? nil : .ignored
        }
        guard cast.isCasting else { return nil }
        switch key {
        case .playPause: cast.togglePlay()
        case .back10: cast.seek(by: -10)
        case .forward10: cast.seek(by: 10)
        case .back60: cast.seek(by: -60)
        case .forward60: cast.seek(by: 60)
        case .volumeUp, .volumeDown:
            cast.changeVolume(by: key == .volumeUp ? 0.05 : -0.05)
            showToast("TV volume \(Int(((cast.status?.volume ?? 0) * 100).rounded())) %")
        case .stats, .options, .fullScreen: return nil
        default:
            showToast("Not while casting · Stop Casting first")
            return .handled
        }
        return .handled
    }

    private func perform(_ key: PlayerKey) -> KeyPress.Result {
        if let handled = performOnTV(key) { return handled }
        switch key {
        case .playPause:
            let willPlay = player.status != .playing
            player.togglePlayPause()
            flashGlyph(willPlay ? "play.fill" : "pause.fill")
        case .back10: Task { await player.seek(by: -10) }; flashGlyph("gobackward.10")
        case .forward10: Task { await player.seek(by: 10) }; flashGlyph("goforward.10")
        case .back60: Task { await player.seek(by: -60) }; flashGlyph("gobackward.60")
        case .forward60: Task { await player.seek(by: 60) }; flashGlyph("goforward.60")
        case .previousChapter: jumpChapter(-1)
        case .nextChapter: jumpChapter(1)
        case .previousFrame: Task { await player.stepFrame(-1) }
        case .nextFrame: Task { await player.stepFrame(1) }
        case .slower: setRate(PlayerSpeeds.step(from: player.rate, by: -1))
        case .faster: setRate(PlayerSpeeds.step(from: player.rate, by: 1))
        case .skipMarker: return skip() ? .handled : .ignored
        case .nextEpisode:
            guard playback.nextEpisode != nil else { showToast("No next episode"); return .handled }
            Task { await playback.playNext(autoplayed: false) }
        case .previousEpisode:
            guard playback.previousEpisode != nil else { showToast("No previous episode"); return .handled }
            Task { await playback.playPrevious() }
        case .volumeUp: sound.stepVolume(10)
        case .volumeDown: sound.stepVolume(-10)
        case .mute:
            player.setMuted(!player.isMuted)
            showToast(player.isMuted ? "Muted" : "Sound on")
        case .dialogueBoost: sound.toggleDialogue()
        case .nightMode: sound.toggleNight()
        case .cycleAudio: cycleAudio()
        case .cycleSubtitles: cycleSubtitles()
        case .subtitleOptions: setOptions(open: !(optionsOpen && optionsPage == .subtitles), page: .subtitles)
        case .findSubtitles: setOptions(open: !(optionsOpen && optionsPage == .search), page: .search)
        case .subtitlesEarlier: shiftSubtitles(by: -0.1)
        case .subtitlesLater: shiftSubtitles(by: 0.1)
        case .generateSubtitles: playback.onDevice.toggleGenerate()
        case .translateSubtitles: playback.onDevice.toggleTranslate()
        case .matchSubtitleTiming: playback.onDevice.toggleMatching()
        case .fullScreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .pictureInPicture:
            guard player.canPictureInPicture else { return .ignored }
            player.togglePictureInPicture()
        case .options: setOptions(open: !optionsOpen)
        case .stats: withAnimation(Theme.Motion.quick) { statsVisible.toggle() }
        case .miniPlayer:
            setOptions(open: false)
            playback.shrink()
        case .whatDidTheySay:
            switch playback.whatDidTheySay(preferred: subtitleSources.languages) {
            case .showing: showToast("Back 10 s with subtitles")
            case .backOnly: flashGlyph("gobackward.10")
            case .noSubtitles: showToast("No subtitles · \(PlayerShortcuts.shared.display(.generateSubtitles)) makes them from speech")
            }
        case .goToTime:
            guard player.duration > 0, !upNextShown else { return .ignored }
            setGoToTime(!goingToTime)
        case .sleepTimer: setOptions(open: !(optionsOpen && optionsPage == .sleep), page: .sleep)
        case .pictureMode:
            withAnimation(Theme.Motion.object(reduceMotion)) { playback.pictureMode = playback.pictureMode.next }
            showToast("Picture: " + playback.pictureMode.label)
        }
        return .handled
    }

    private func setRate(_ rate: Double) {
        player.setRate(rate)
        showToast(rate == 1 ? "Normal speed" : String(format: "%g× speed", rate))
    }

    /// Plex's chapter list, else the file's own.
    private var chapterStarts: [(title: String, start: Double)] {
        let plex = item.chapters.map { ($0.tag ?? "", $0.start) }
        if !plex.isEmpty { return plex.sorted { $0.1 < $1.1 } }
        return player.chapters.map { ($0.title, $0.start) }.sorted { $0.1 < $1.1 }
    }

    private func jumpChapter(_ direction: Int) {
        let chapters = chapterStarts
        guard !chapters.isEmpty else { showToast("No chapters"); return }
        let now = player.currentTime
        // Within 3 s of a chapter's start, ← goes to the one before (as on a disc player).
        let target = direction > 0 ? chapters.firstIndex { $0.start > now + 1 }
                                   : chapters.lastIndex { $0.start < now - 3 }
        guard let i = target else {
            if direction < 0 { Task { await player.seek(to: 0) }; showToast("Start") } else { showToast("Last chapter") }
            return
        }
        Task { await player.seek(to: chapters[i].start, exact: true) }
        let title = chapters[i].title
        showToast(title.isEmpty || title.hasPrefix("Chapter") ? "Chapter \(i + 1)" : "Chapter \(i + 1) · \(title)")
    }

    private func cycleAudio() {
        let tracks = player.audioTracks
        guard tracks.count > 1 else { showToast(tracks.isEmpty ? "No audio tracks" : "Only one audio track"); return }
        let i = tracks.firstIndex { $0.id == player.selectedAudioID } ?? -1
        let next = tracks[(i + 1) % tracks.count]
        playback.selectAudio(trackID: next.id)
        showToast("Audio: " + Format.trackName(next))
    }

    private func cycleSubtitles() {
        let options: [PlayerTrack?] = [nil] + player.subtitleTracks.map(Optional.some)
        guard options.count > 1 else { showToast("No subtitles"); return }
        let i = options.firstIndex { $0?.id == player.selectedSubtitleID } ?? 0
        let next = options[(i + 1) % options.count]
        playback.selectSubtitle(trackID: next?.id)
        showToast("Subtitles: " + (next.map(Format.trackName) ?? "Off"))
    }

    private func shiftSubtitles(by delta: Double) {
        subtitleOffset = ((subtitleOffset + delta) * 10).rounded() / 10
        showToast(subtitleOffset == 0 ? "Subtitles on time" : String(format: "Subtitles %+.1f s", subtitleOffset))
    }

    /// Saves the frame on screen, full size, to Pictures ▸ Mezzanine and copies it.
    private func takeSnapshot() {
        let time = player.currentTime
        let name = Snapshot.fileName(for: item, at: time)
        Task {
            guard let image = await player.snapshot() else { showToast("Couldn’t take a snapshot"); return }
            switch Snapshot.save(image, named: name) {
            case .success: showToast("Snapshot saved to Pictures ▸ Mezzanine")
            case .failure: showToast("Snapshot copied (couldn’t save to Pictures)")
            }
        }
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

    /// `long`: a problem, kept up long enough to read.
    private func showToast(_ text: String, long: Bool = false) {
        withAnimation(Theme.Motion.quick) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(long ? 5 : 1.4))
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
    var chapters: [(title: String, start: Double)] = []
    /// A frame near a time, for the hover preview; nil shows the time alone.
    var preview: ((Double) async -> CGImage?)? = nil
    let seek: (Double) -> Void
    @State private var hoverX: CGFloat?
    @State private var thumb: (bucket: Int, image: CGImage)?
    @State private var cache: [Int: CGImage] = [:]
    @State private var fetch: Task<Void, Never>?

    /// Previews are fetched per 5 s slice, so sweeping along the bar reuses them.
    private static let slice = 5.0

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
                if duration > 0, chapters.count > 1, chapters.count < 80 {
                    // Chapter starts: small gaps cut into the bar.
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, c in
                        if c.start > 1 {
                            Rectangle().fill(.black.opacity(0.7)).frame(width: 2, height: thick)
                                .offset(x: w * c.start / duration - 1)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                // Anchored to the bar's bottom edge and lifted clear of it, growing upward.
                if let x = hoverX, duration > 0 {
                    let t = Double(x / w) * duration
                    let cw = cardWidth(at: t) + (shownImage(at: t) == nil ? 0 : 8)
                    hoverCard(at: t)
                        .fixedSize()
                        .offset(x: min(max(Theme.Space.s, x - cw / 2), w - cw - Theme.Space.s), y: -(thick + 10))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                withAnimation(Theme.Motion.quick) {
                    if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
                }
                if case .active(let point) = phase, w > 0 {
                    requestPreview(Double(point.x / w) * duration)
                } else {
                    fetch?.cancel()
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard duration > 0 else { return }
                seek(max(0, min(duration, Double(v.location.x / w) * duration)))
            })
            #if DEBUG
            // -ScrubHoverAt 0.7: pretend the pointer rests on the bar there, for review captures.
            .task(id: duration > 0) {
                let f = UserDefaults.standard.double(forKey: "ScrubHoverAt")
                guard f > 0, duration > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
                hoverX = w * f
                requestPreview(Double(f) * duration)
            }
            #endif
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

    // MARK: Hover preview

    private func bucket(_ t: Double) -> Int { Int(max(0, t) / Self.slice) }

    private func shownImage(at t: Double) -> CGImage? {
        guard let thumb, thumb.bucket == bucket(t) else { return nil }
        return thumb.image
    }

    private func cardWidth(at t: Double) -> CGFloat { shownImage(at: t) == nil ? 72 : 200 }

    private func chapterTitle(at t: Double) -> String? {
        guard chapters.count > 1, let i = chapters.lastIndex(where: { $0.start <= t }) else { return nil }
        let title = chapters[i].title
        return title.isEmpty || title.hasPrefix("Chapter") ? "Chapter \(i + 1)" : title
    }

    /// The frame (when one is ready), the chapter, and the time.
    private func hoverCard(at t: Double) -> some View {
        VStack(spacing: 4) {
            if let image = shownImage(at: t) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)
                    .frame(width: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let chapter = chapterTitle(at: t), shownImage(at: t) != nil {
                Text(chapter).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Text(clock(t)).font(Theme.Typeface.cardMeta.monospacedDigit()).foregroundStyle(Theme.ink)
        }
        .padding(shownImage(at: t) == nil ? EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8) : EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4))
        .frame(width: cardWidth(at: t) + (shownImage(at: t) == nil ? 0 : 8))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.graphite.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
    }

    private func requestPreview(_ t: Double) {
        guard let preview, duration > 0 else { return }
        let b = bucket(t)
        if thumb?.bucket == b { return }
        if let image = cache[b] { thumb = (b, image); return }
        fetch?.cancel()
        fetch = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            guard let image = await preview(min(duration - 1, (Double(b) + 0.5) * Self.slice)) else { return }
            if cache.count > 240 { cache.removeAll() }
            cache[b] = image
            if !Task.isCancelled { thumb = (b, image) }
        }
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

/// The stage's part in on-device subtitles (M12): readouts, the menu's checkmarks, and the
/// translation session, which runs here while the player is up (the system asks to
/// download a language pair the first time).
private struct OnDeviceHost: ViewModifier {
    let onDevice: OnDeviceSubtitles
    let commands: AppCommandCenter
    let toast: (String, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: onDevice.announcement?.id) { _, _ in
                if let note = onDevice.announcement { toast(note.text, note.long) }
            }
            .onChange(of: onDevice.showsGenerated, initial: true) { _, v in commands.generatingSubtitles = v }
            .onChange(of: onDevice.translates, initial: true) { _, v in commands.translatingSubtitles = v }
            .onChange(of: onDevice.isMatching, initial: true) { _, v in commands.matchingSubtitleTiming = v }
            .onChange(of: onDevice.canMatch, initial: true) { _, v in commands.canMatchSubtitleTiming = v }
            .onChange(of: onDevice.targetLanguage, initial: true) { _, code in
                commands.subtitleTranslateTarget = OnDeviceSubtitles.languageName(code)
            }
            .translationTask(onDevice.translationConfiguration) { session in
                await onDevice.serve(session)
            }
    }
}

/// Text and bitmap subtitles over the picture, styled from the ⋯ panel. Generated lines
/// (from speech) replace the engine's when they're on; Translate swaps each text line for
/// its translation once it has arrived.
struct SubtitleOverlay: View {
    let player: MezzaninePlayer
    let onDevice: OnDeviceSubtitles
    /// The mini player's tile: smaller type, closer to the edge.
    var compact = false
    @AppStorage("subtitleScale") private var scale: Double = 1
    @AppStorage("subtitleBackground") private var background = false
    @AppStorage("subtitleOffset") private var offset: Double = 0

    private enum Shown: Identifiable {
        case text(id: String, String)
        case image(id: Int, CGImage)
        var id: String {
            switch self {
            case .text(let id, _): id
            case .image(let id, _): "image-\(id)"
            }
        }
    }

    private var shown: [Shown] {
        let now = player.currentTime - offset
        if onDevice.showsGenerated {
            return onDevice.lines.filter { $0.start <= now && now < $0.end }
                .map { .text(id: "g-\($0.start)", onDevice.display($0.text)) }
        }
        return player.cues.filter { $0.start <= now && now < $0.end }.map { cue in
            switch cue.content {
            case .text(let text): .text(id: "c-\(cue.id)", onDevice.display(text))
            case .image(let image, _): .image(id: cue.id, image)
            }
        }
    }

    var body: some View {
        let active = shown
        GeometryReader { geo in
            // Size follows the picture so subtitles read the same in a window and full screen.
            let size = (compact ? max(9, geo.size.height * 0.075) : max(16, geo.size.height * 0.042)) * scale
            VStack(spacing: 6) {
                ForEach(active) { line in
                    switch line {
                    case .text(_, let text):
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
                    case .image(_, let image):
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxHeight: geo.size.height * 0.2 * scale)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, geo.size.height * (compact ? 0.05 : 0.07))
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
    /// Offered while playing the original file: let Plex convert it instead.
    let convert: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Playback stopped", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: Theme.Space.m) {
                Button("Try Again", action: retry).buttonStyle(PrimaryButtonStyle()).focusEffectDisabled(false)
                    .help("Try again (Return)")
                if let convert {
                    Button("Convert on the Server", action: convert).buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                        .help("Plex converts the file as it plays. Uses the server’s processor.")
                }
                Button("Close", action: close).buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                    .help("Close (Esc)")
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

#if DEBUG
/// Builds and posts key events for `-PlayerKeyScript`.
enum DebugKeys {
    /// The launch key script runs once, not again when the player reappears (mini player).
    static var scriptRan = false
    static func post(_ token: String) {
        let parts = token.lowercased().split(separator: "+").map(String.init)
        var flags: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "shift": flags.insert(.shift)
            case "opt", "option": flags.insert(.option)
            case "cmd": flags.insert(.command)
            case "cmdshift": flags.formUnion([.command, .shift])
            default: break
            }
        }
        let key = parts.last ?? ""
        let named: [String: (UInt16, String)] = [
            "space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"),
            "down": (125, "\u{F701}"), "esc": (53, "\u{1B}"), "ret": (36, "\r"),
        ]
        let (code, base) = named[key] ?? (0, key)
        let chars = flags.contains(.shift) && named[key] == nil ? base.uppercased() : base
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
