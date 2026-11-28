import SwiftUI
import MezzanineKit

/// Sleeve's two columns: the art, name and actions stay put on the left (it scrolls only if the
/// window is too short for it), and the list scrolls beside it. The art squeezes from 340 pt down to
/// 190 pt as the window narrows, so a 900 pt window still has room for the list.
struct SleevePage<Left: View, Right: View>: View {
    @ViewBuilder let left: (CGFloat) -> Left
    @ViewBuilder let right: (CGFloat) -> Right

    static var maxArt: CGFloat { 340 }

    var body: some View {
        GeometryReader { geo in
            let art = min(Self.maxArt, max(190, (geo.size.width - Theme.Space.gutter * 2) * 0.38))
            let leftWidth = Theme.Space.gutter + art + 24
            let rightWidth = max(240, geo.size.width - leftWidth - Theme.Space.gutter)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    left(art)
                        .padding(.leading, Theme.Space.gutter)
                        .padding(.trailing, 24)
                        .padding(.top, Theme.Space.l)
                        .padding(.bottom, Theme.Space.xl)
                        .frame(width: leftWidth, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(width: leftWidth)
                ScrollView {
                    right(rightWidth)
                        .padding(.trailing, Theme.Space.gutter)
                        .padding(.top, Theme.Space.l)
                        .padding(.bottom, Theme.Space.xl)
                        .frame(width: rightWidth + Theme.Space.gutter, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// The art block of a sleeve: the cover at full column width with the deep shadow.
struct SleeveArt: View {
    let path: String?
    var round = false
    let size: CGFloat

    var body: some View {
        MusicArt(path: path, round: round, pixelWidth: Int(size * 2))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 22, y: 22)
            .shadow(color: .black.opacity(0.4), radius: 5, y: 4)
    }
}
