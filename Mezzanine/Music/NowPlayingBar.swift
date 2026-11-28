import SwiftUI
import AVKit
import MezzanineKit
import MezzaninePlayback

/// The docked Now Playing bar: a 16 pt Liquid Glass panel at the bottom of the detail column, on
/// every page (it hangs outside the navigation stack) and absent while nothing is queued or a
/// video is on screen. The art and title open the playing album (the Now Playing room itself is
/// Music M3, and will slide up from here).
///
/// Wide (1000 pt and more): art and name, transport with both times, the Up Next count, AirPlay and
/// volume. Narrower, the extras go first: the volume (under 1000), then AirPlay and the count
/// (under 800), then the two times (under 700), and under 600 only art, name and play stay.
/// A 2 pt line along the bottom edge is the progress; a 20 pt strip at the bottom edge, and
/// nothing else, scrubs. Keys are the Controls menu's.
struct NowPlayingBar: View {
    @Environment(MusicSession.self) private var music
    @Environment(MusicActions.self) private var actions
    @Environment(SessionStore.self) private var session
    @State private var width: CGFloat = 1000
    @State private var scrub: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous) }
    private var isFull: Bool { width >= 1000 }
    private var showsExtras: Bool { width >= 800 }
    private var showsTimes: Bool { width >= 700 }
    private var showsSkips: Bool { width >= 600 }

    var body: some View {
        if let track = music.queue.current {
            HStack(spacing: 20) {
                nameplate(track).frame(maxWidth: .infinity, alignment: .leading)
                transport(track)
                if showsExtras { trailing.frame(maxWidth: .infinity, alignment: .trailing) }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            // Behind the controls, so a click on one of them never reaches the scrub strip.
            .background(alignment: .bottom) { scrubStrip }
            .modifier(BarSurface(shape: shape, solid: reduceTransparency, strongRule: contrast == .increased))
            .overlay(alignment: .bottom) { progressLine.clipShape(shape).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
            .transition(.opacity)
        }
    }

    // MARK: Parts

    /// A key as it is bound now, for tooltips.
    private func key(_ action: MusicKey) -> String { MusicShortcuts.shared.display(action) }

    private func nameplate(_ track: QueuedTrack) -> some View {
        Button { actions.showPlaying() } label: {
            HStack(spacing: 12) {
                MusicArt(path: track.thumb, pixelWidth: 96, radius: 8)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(MusicFormat.songTitle(track.title)).font(.system(.body, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle(track)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the album (\(key(.nowPlaying)))")
        .accessibilityLabel(([MusicFormat.songTitle(track.title)] + facts(track)).joined(separator: ", "))
        .accessibilityHint("Opens")
    }

    private func facts(_ track: QueuedTrack) -> [String] {
        if case .failed = music.status { return ["Couldn’t play this song"] }
        return [track.artist, track.album].filter { !$0.isEmpty }
    }

    private func subtitle(_ track: QueuedTrack) -> String { facts(track).joined(separator: " · ") }

    private func transport(_ track: QueuedTrack) -> some View {
        HStack(spacing: 14) {
            if showsTimes {
                Text(Format.clock(shown)).frame(width: 40, alignment: .trailing).accessibilityHidden(true)
            }
            if showsSkips {
                Button { music.previous() } label: { Image(systemName: "backward.fill").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Previous (\(key(.previousTrack)))")
                    .accessibilityLabel("Previous Track")
            }
            Button { music.togglePlayPause() } label: {
                Group {
                    if music.status == .loading {
                        ProgressView().controlSize(.small).tint(Theme.graphite)
                    } else {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(Theme.graphite)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.ink))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("\(music.isPlaying ? "Pause" : "Play") (\(key(.playPause)))")
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            if showsSkips {
                Button { music.next() } label: { Image(systemName: "forward.fill").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Next (\(key(.nextTrack)))")
                    .accessibilityLabel("Next Track")
                    .disabled(music.queue.peekNext == nil)
            }
            if showsTimes {
                Text("−" + Format.clock(max(0, music.duration - shown))).frame(width: 40, alignment: .leading).accessibilityHidden(true)
            }
        }
        .font(Theme.Typeface.cardMeta)
        .foregroundStyle(Theme.ink)
        .labelStyle(.iconOnly)
    }

    private var trailing: some View {
        HStack(spacing: 10) {
            let n = music.queue.upNext.count
            Text(n == 0 ? "Nothing up next" : "\(n) up next")
                .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            AirPlayButton().frame(width: 28, height: 28).help("AirPlay").accessibilityLabel("AirPlay")
            if isFull {
                Image(systemName: music.volume == 0 ? "speaker.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(Theme.inkSecondary).accessibilityHidden(true)
                Slider(value: Binding(get: { Double(music.volume) }, set: { music.volume = Float($0) }), in: 0...1)
                    .controlSize(.small)
                    .tint(Theme.ink)
                    .frame(width: 84)
                    .accessibilityLabel("Volume")
                    .help("Volume (\(key(.volumeUp)) \(key(.volumeDown)))")
            }
        }
    }

    // MARK: Progress

    /// Where the bar says the song is: the pointer's while scrubbing, else the engine's.
    private var shown: Double { scrub.map { $0 * music.duration } ?? music.position }
    private var fraction: Double { music.duration > 0 ? min(1, max(0, shown / music.duration)) : 0 }

    /// Height of the strip along the bottom edge that scrubs. Nothing above it does.
    static let scrubHeight: CGFloat = 20

    /// The 2 pt progress line; it never takes a click.
    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Theme.ink.opacity(0.2)).frame(height: 2)
                Rectangle().fill(Theme.ink).frame(width: geo.size.width * fraction, height: 2)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 64)
    }

    /// A 20 pt strip at the bottom edge: a click or drag seeks, and it is the bar's one
    /// "Position" element for VoiceOver (Up and Down arrows step 10 s).
    private var scrubStrip: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        scrub = min(1, max(0, drag.location.x / max(1, geo.size.width)))
                    }
                    .onEnded { _ in
                        guard let target = scrub else { return }
                        scrub = nil
                        Task { await music.seek(to: target * music.duration) }
                    })
        }
        .frame(height: Self.scrubHeight)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(MusicFormat.spoken(seconds: music.position)) of \(MusicFormat.spoken(seconds: music.duration))")
        .accessibilityAdjustableAction { direction in
            music.skip(by: direction == .increment ? 10 : -10)
        }
    }
}

/// The bar's panel: Liquid Glass, or a solid Raised fill under Reduce Transparency; the rule
/// strengthens under Increase Contrast.
private struct BarSurface: ViewModifier {
    let shape: RoundedRectangle
    let solid: Bool
    let strongRule: Bool

    func body(content: Content) -> some View {
        Group {
            if solid {
                content.background(shape.fill(Theme.raised))
            } else {
                content.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            }
        }
        .overlay(shape.strokeBorder(strongRule ? Theme.inkSecondary : Theme.rule, lineWidth: strongRule ? 2 : 1))
    }
}

/// The system AirPlay picker, drawn quietly next to the transport.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
