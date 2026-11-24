import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// Runs the sleep timer: fades the sound over the last seconds, then pauses (or lets nothing
/// follow the title). It belongs to the playback, not the stage, so Up Next and the mini player
/// don't lose it. Paused, `KeepAwake` lets go and the Mac sleeps as usual.
@MainActor
@Observable
final class SleepControl {
    private(set) var timer = SleepTimer()
    /// Seconds until it stops, while the sound fades (the player shows Keep Watching).
    private(set) var stopping: Int?
    /// Bumped each time it stops playback (the stage says so, and Up Next stops counting).
    private(set) var stops = 0

    @ObservationIgnored private weak var playback: PlaybackCoordinator?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var ramp: Task<Void, Never>?
    @ObservationIgnored private var isRamping = false

    func attach(_ playback: PlaybackCoordinator) { self.playback = playback }

    var isOn: Bool { timer.choice != .off }

    func set(_ choice: SleepTimer.Choice) {
        timer.set(choice)
        #if DEBUG
        // -SleepTimerSeconds 30: a timed choice ends that soon.
        let seconds = UserDefaults.standard.integer(forKey: "SleepTimerSeconds")
        if seconds > 0, case .minutes(let n) = choice { timer.set(choice, now: Date().addingTimeInterval(Double(seconds - n * 60))) }
        #endif
        endFade()
        run()
    }

    func keepWatching() {
        guard isOn else { return }
        timer.keepWatching()
        endFade()
        run()
    }

    /// The title reached its end. True when nothing may follow it; the timer is then done.
    func titleEnded() -> Bool {
        guard timer.stopsAtEnd else { return false }
        finish(quietly: true)
        return true
    }

    /// The player closed: nothing left to stop.
    func playerClosed() {
        timer.set(.off)
        loop?.cancel()
        ramp?.cancel()
        isRamping = false
        stopping = nil
        playback?.player.fade = 1
    }

    /// "23 min", "End of episode"; "Off".
    func label(for item: PlexMetadata?) -> String {
        switch timer.choice {
        case .off: "Off"
        case .endOfTitle: Self.endLabel(item)
        case .minutes: timer.left(remaining: nil).map { "\(max(1, Int(($0 / 60).rounded(.up)))) min" } ?? "Off"
        }
    }

    static func endLabel(_ item: PlexMetadata?) -> String {
        item?.kind == .episode ? "End of episode" : "End of film"
    }

    // MARK: Running

    private func run() {
        loop?.cancel()
        guard isOn else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isOn else { return }
                self.tick()
                try? await Task.sleep(for: self.stopping == nil ? .seconds(1) : .milliseconds(250))
            }
        }
    }

    private func tick() {
        guard let playback else { return }
        let player = playback.player
        let casting = playback.cast.isCasting
        let remaining = player.duration > 0 ? (player.duration - player.currentTime) / max(0.1, player.rate) : nil
        switch timer.phase(remaining: casting ? nil : remaining) {
        case .idle, .waiting:
            endFade()
        case .fading(let seconds, let level):
            switch player.status {
            case .playing where !casting: break
            // Between two pictures: hold the level, or it would swell back for a moment.
            case .seeking, .loading: return
            default: endFade(); return
            }
            if stopping == nil {
                AccessibilityNotification.Announcement(playback.isMini
                    ? "Sleep timer. Stopping in \(seconds) seconds. Keep Watching is on the mini player."
                    : "Sleep timer. Stopping in \(seconds) seconds. Return keeps watching.").post()
            }
            #if DEBUG
            if stopping != seconds { print("SLEEP stopping in \(seconds) fade \(String(format: "%.2f", level)) status \(player.status)") }
            #endif
            ramp?.cancel()
            stopping = seconds
            player.fade = level
        case .due:
            let stopsIt = [.playing, .seeking, .loading].contains(player.status) && !casting
            if stopsIt { player.pause() }
            // Already paused by hand: there's nothing to say.
            finish(quietly: !stopsIt)
        }
    }

    private func finish(quietly: Bool) {
        timer.set(.off)
        loop?.cancel()
        stopping = nil
        if !quietly {
            stops += 1
            AccessibilityNotification.Announcement("Sleep timer. Playback paused.").post()
        }
        AppLog.playback.notice("sleep timer ended")
        // The level comes back once the sound has stopped, so nothing is heard of it.
        ramp?.cancel()
        ramp = Task { [weak self] in
            for _ in 0..<30 {
                guard let player = self?.playback?.player, player.status == .playing else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let self, !self.isOn else { return }
            self.playback?.player.fade = 1
            #if DEBUG
            if let player = self.playback?.player { print("SLEEP ended, fade \(player.fade) status \(player.status)") }
            #endif
        }
    }

    /// Back to the full level: over a second while it plays, at once otherwise.
    private func endFade() {
        if stopping != nil { stopping = nil }
        guard let player = playback?.player, player.fade < 1 else { return }
        guard player.status == .playing else { ramp?.cancel(); player.fade = 1; return }
        guard !isRamping else { return }
        isRamping = true
        ramp = Task { [weak self] in
            defer { self?.isRamping = false }
            while let player = self?.playback?.player, player.fade < 1, !Task.isCancelled {
                player.fade = min(1, player.fade + 0.05)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// The last seconds before the timer stops playback, where Still Watching asks.
struct StoppingSoonCard: View {
    let seconds: Int
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Stopping in \(seconds) s").font(Theme.Typeface.messageTitle).foregroundStyle(Theme.ink)
                .contentTransition(.numericText(countsDown: true))
                .accessibilityAddTraits(.isHeader)
            Button("Keep Watching", action: keep)
                .buttonStyle(PrimaryButtonStyle())
                .focusEffectDisabled(false)
                .help("Keep watching (Return)")
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep timer")
    }
}

/// Go to Time: a small field over the scrub bar.
struct GoToTimeField: View {
    let duration: TimeInterval
    let go: (TimeInterval) -> Void
    let close: () -> Void

    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Go to time", text: $text, prompt: Text("1:02:30 or minutes"))
                .textFieldStyle(.plain)
                .font(Theme.Typeface.cardHeadline.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand(perform: close)
                .onChange(of: text) { _, _ in problem = nil }
            Text(problem ?? "Return goes there · Esc closes")
                .font(Theme.Typeface.cardMeta)
                .foregroundStyle(problem == nil ? Theme.inkSecondary : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 260, maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.graphite.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to time")
    }

    private func submit() {
        guard let seconds = TimeEntry.seconds(text) else { say("Type a time like 1:02:30, or minutes."); return }
        guard duration <= 0 || seconds < duration else { say("This ends at \(Format.clock(duration))."); return }
        go(seconds)
    }

    private func say(_ message: String) {
        problem = message
        AccessibilityNotification.Announcement(message).post()
    }
}

/// The sleep timer's choices in words.
enum SleepWords {
    static func label(_ choice: SleepTimer.Choice, episode: Bool) -> String {
        switch choice {
        case .off: "Off"
        case .endOfTitle: episode ? "End of Episode" : "End of Film"
        case .minutes(let n): "\(n) Minutes"
        }
    }
}
