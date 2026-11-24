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
        finish()
        return true
    }

    /// The player closed: nothing left to stop.
    func playerClosed() {
        timer.set(.off)
        loop?.cancel()
        endFade()
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
        let playing = player.status == .playing && !casting
        let remaining = player.duration > 0 ? (player.duration - player.currentTime) / max(0.1, player.rate) : nil
        switch timer.phase(remaining: casting ? nil : remaining) {
        case .idle, .waiting:
            endFade()
        case .fading(let seconds, let level):
            // Paused or on a TV there's no sound here to fade.
            guard playing else { endFade(); return }
            if stopping == nil {
                AccessibilityNotification.Announcement("Sleep timer. Stopping in \(seconds) seconds. Return keeps watching.").post()
            }
            stopping = seconds
            player.fade = level
        case .due:
            if casting {
                if playback.cast.isPlaying { playback.cast.togglePlay() }
            } else if player.status == .playing || player.status == .seeking || player.status == .loading {
                player.pause()
            }
            finish()
        }
    }

    private func finish() {
        timer.set(.off)
        loop?.cancel()
        stopping = nil
        stops += 1
        AppLog.playback.notice("sleep timer stopped playback")
        AccessibilityNotification.Announcement("Sleep timer ended").post()
        // The level comes back once the pause has landed, so nothing is heard of it.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !isOn { playback?.player.fade = 1 }
        }
    }

    private func endFade() {
        if stopping != nil { stopping = nil }
        if let player = playback?.player, player.fade != 1 { player.fade = 1 }
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
        .frame(width: 260, alignment: .leading)
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
