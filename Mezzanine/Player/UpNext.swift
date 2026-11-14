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
                    .font(Theme.Typeface.cardHeadline).foregroundStyle(Theme.ink).lineLimit(2)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up Next: \(next.title), starts in \(seconds) seconds")
    }
}

/// A small ring that empties as the countdown runs.
private struct CountdownRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(Theme.onLilac.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: fraction).stroke(Theme.onLilac, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// After several episodes in a row: pause and ask.
struct StillWatchingCard: View {
    let resume: () -> Void
    let stop: () -> Void
    @AccessibilityFocusState private var focusResume: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Still watching?").font(Theme.Typeface.messageTitle).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Mezzanine paused before the next episode.").font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
            HStack(spacing: Theme.Space.m) {
                Button("Keep Watching", action: resume)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled(false)
                    .accessibilityFocused($focusResume)
                Button("Stop", action: stop)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
            }
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .onAppear { focusResume = true }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// After a film: the picture shrinks as it does for Up Next, and this card offers what to
/// watch next. No countdown: films don't autoplay. Arrows choose, Return plays, Esc keeps the
/// credits running.
struct PostPlayCard: View {
    let title: String
    let suggestions: [PlexMetadata]
    let selected: Int
    let select: (Int) -> Void
    let play: (PlexMetadata) -> Void
    let replay: () -> Void
    let hide: () -> Void

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let posterWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            if suggestions.isEmpty {
                Text("Nothing else to suggest from this film.")
                    .font(Theme.Typeface.body).foregroundStyle(Theme.inkTertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.posterWidth), spacing: Theme.Space.m), count: 3),
                          alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.ratingKey) { i, item in
                        suggestion(item, index: i)
                    }
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button("Watch Again", action: replay)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                    .help("Start this film again")
                Button("Keep Watching Credits", action: hide)
                    .buttonStyle(SecondaryButtonStyle()).focusEffectDisabled(false)
                    .help("Hide suggestions (Esc)")
            }
        }
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). Arrow keys choose, Return plays.")
    }

    private func suggestion(_ item: PlexMetadata, index: Int) -> some View {
        let isSelected = index == selected
        return Button { play(item) } label: {
            VStack(alignment: .leading, spacing: 4) {
                RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: Int(Self.posterWidth * 2)),
                            pixelWidth: Int(Self.posterWidth * 2))
                    .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .shadow(color: .black.opacity(isSelected ? 0.6 : 0.3), radius: isSelected ? 18 : 6, y: isSelected ? 10 : 3)
                    .scaleEffect(isSelected && !reduceMotion ? 1.04 : 1, anchor: .bottom)
                    .animation(Theme.Motion.lift, value: isSelected)
                Text(Format.displayTitle(item))
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                Text(item.year.map(String.init) ?? "")
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
            }
            .frame(width: Self.posterWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        // Only a moving pointer selects (rows never steal the keyboard's choice by appearing under it).
        .onContinuousHover { phase in if case .active = phase, !isSelected { select(index) } }
        .accessibilityLabel([Format.displayTitle(item), item.year.map(String.init)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Plays it")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
