import SwiftUI
import MezzanineKit

/// The next episode, counting down beside the shrunken picture.
struct UpNextCard: View {
    let next: PlexMetadata
    let seconds: Int
    let total: Int
    let playNow: () -> Void
    let hide: () -> Void

    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Up Next").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            RemoteImage(url: session.backdropURL(next.thumb, pixelWidth: 760), pixelWidth: 760)
                .frame(width: 380, height: 214)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text([Format.episodeCode(next), next.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                if let summary = next.summary, !summary.isEmpty {
                    Text(summary).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button(action: playNow) {
                    HStack(spacing: 8) {
                        CountdownRing(fraction: total > 0 ? Double(seconds) / Double(total) : 0)
                        Text("Play Now")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .focusEffectDisabled(false)
                .help("Play now (Return)")
                Button("Hide", action: hide)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                    .help("Keep watching the credits (Esc)")
            }
            Text("Starts in \(seconds) s").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 380, alignment: .leading)
        .padding(.trailing, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up Next: \(next.title), starts in \(seconds) seconds")
    }
}

/// A small ring that empties as the countdown runs.
private struct CountdownRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.onLilac.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: fraction).stroke(Theme.onLilac, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// After several episodes in a row: pause and ask.
struct StillWatchingCard: View {
    let resume: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Still watching?").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Mezzanine paused before the next episode.").font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
            HStack(spacing: Theme.Space.m) {
                Button("Keep Watching", action: resume)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled(false)
                Button("Stop", action: stop)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
            }
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
